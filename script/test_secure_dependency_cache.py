#!/usr/bin/env python3
"""Temporary fake artifacts only; never compile/download or modify production caches."""
import argparse
import copy
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import secure_dependency_cache as cache


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.inputs = {"version": "1", "sha256": "pinned", "architecture": "arm64", "toolchain": "clang", "sdk": "sdk", "parameters": ["static"]}
        (self.root / "lib").mkdir()
        (self.root / "lib/fake.a").write_bytes(b"fake static artifact")

    def testCompletedArtifactReuseRequiresAllInputsAndExactContents(self):
        cache.complete(self.root, self.inputs)
        self.assertTrue(cache.matches(self.root, self.inputs))
        for field in self.inputs:
            changed = copy.deepcopy(self.inputs)
            changed[field] = ["changed"] if field == "parameters" else "changed"
            self.assertNotEqual(cache.fingerprint(changed), cache.fingerprint(self.inputs))
            self.assertFalse(cache.matches(self.root, changed), field)
        (self.root / "lib/fake.a").write_bytes(b"corrupt")
        self.assertFalse(cache.matches(self.root, self.inputs))

    def testLibraryWithoutManifestAndMalformedOrUnsupportedManifestNeverReuse(self):
        self.assertFalse(cache.matches(self.root, self.inputs))
        for contents in [b"broken", b"[]", b"null", b'{}']:
            (self.root / "manifest.json").write_bytes(contents)
            self.assertFalse(cache.matches(self.root, self.inputs))
        cache.complete(self.root, self.inputs)
        manifest = json.loads((self.root / "manifest.json").read_text())
        manifest["schema"] = 999
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        self.assertFalse(cache.matches(self.root, self.inputs))

    def testMissingExtraOrSymlinkedArtifactsInvalidateCompletion(self):
        cache.complete(self.root, self.inputs)
        (self.root / "extra").write_bytes(b"unrecorded")
        self.assertFalse(cache.matches(self.root, self.inputs))
        (self.root / "extra").unlink()
        (self.root / "lib/fake.a").unlink()
        self.assertFalse(cache.matches(self.root, self.inputs))
        (self.root / "lib/fake.a").symlink_to(self.root / "manifest.json")
        self.assertFalse(cache.matches(self.root, self.inputs))

    def testAtomicCompletionFailureKeepsPreviousManifestAndDoesNotPublishPartial(self):
        cache.complete(self.root, self.inputs)
        before = (self.root / "manifest.json").read_bytes()
        with patch.object(cache.os, "replace", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                cache.complete(self.root, {"version": "new"})
        self.assertEqual((self.root / "manifest.json").read_bytes(), before)
        self.assertEqual(list(self.root.glob("manifest.json.*")), [])

    def testBuildBoundaryReusesMatchingObjectsButRebuildsChangedParameters(self):
        args = argparse.Namespace(root=str(self.root), ssh_version="1.11.1", ssl_version="3.5.9", ssh_sha="pin", ssl_sha="pin")
        with patch.object(cache, "toolchain", return_value={"sdk": "fixture-sdk"}):
            builder = cache.Builder(args)
        inputs = builder.inputs["arm64"][0]
        calls = []
        def extract(archive, destination):
            source = destination / ("openssl-" + args.ssl_version)
            source.mkdir(); (source / "LICENSE.txt").write_text("fixture license")
        def run(*arguments, **kwargs):
            calls.append(arguments)
            if arguments[0] == "./Configure":
                prefix = Path(next(str(a).split("=", 1)[1] for a in arguments if str(a).startswith("--prefix=")))
                (prefix / "lib").mkdir(parents=True)
                for name in ["libcrypto.a", "libssl.a"]:
                    (prefix / "lib" / name).write_bytes(b"fake static output")
        with patch.object(cache, "extract", side_effect=extract), patch.object(cache, "run", side_effect=run), patch.object(cache, "check_arch"):
            built = builder.build_one(inputs, self.root / "fake.tar.gz")
            first_calls = len(calls)
            self.assertTrue(cache.matches(built, inputs))
            self.assertEqual(builder.build_one(inputs, self.root / "fake.tar.gz"), built)
            self.assertEqual(len(calls), first_calls)
            changed = copy.deepcopy(inputs); changed["parameters"].append("new-parameter")
            new = builder.build_one(changed, self.root / "fake.tar.gz")
            self.assertNotEqual(new, built); self.assertGreater(len(calls), first_calls)
            (new / "manifest.json").unlink()
            before = len(calls)
            builder.build_one(changed, self.root / "fake.tar.gz")
            self.assertGreater(len(calls), before)

    def testWrongLibraryVersionMarkerBlocksMerge(self):
        with patch.object(cache, "run", return_value="1.11.1\nOpenSSL 3.5.9 fixture date"):
            cache.check_library_version(self.root / "lib/fake.a", "libssh2", "1.11.1")
            cache.check_library_version(self.root / "lib/fake.a", "openssl", "3.5.9")
            for dependency in ["libssh2", "openssl"]:
                with self.assertRaises(ValueError):
                    cache.check_library_version(self.root / "lib/fake.a", dependency, "old")

    def testOpenSSLKeyInvalidatesSSHAndUniversalKeys(self):
        args = argparse.Namespace(root=str(self.root), ssh_version="1.11.1", ssl_version="3.5.9", ssh_sha="ssh-pin", ssl_sha="ssl-pin")
        with patch.object(cache, "toolchain", return_value={"sdk": "fixture-sdk", "compiler": "fixture-clang"}):
            before = cache.Builder(args)
            args.ssl_sha = "changed-ssl-pin"
            after = cache.Builder(args)
        for arch in cache.ARCHES:
            self.assertNotEqual(cache.fingerprint(before.inputs[arch][0]), cache.fingerprint(after.inputs[arch][0]))
            self.assertNotEqual(cache.fingerprint(before.inputs[arch][1]), cache.fingerprint(after.inputs[arch][1]))
        self.assertNotEqual(before.generation(), after.generation())

    def testSDKCompilerArchitectureAndParametersChangeKeys(self):
        args = argparse.Namespace(root=str(self.root), ssh_version="1.11.1", ssl_version="3.5.9", ssh_sha="ssh-pin", ssl_sha="ssl-pin")
        with patch.object(cache, "toolchain", return_value={"sdk": "sdk-A", "compiler": "clang-A"}):
            first = cache.Builder(args)
        with patch.object(cache, "toolchain", return_value={"sdk": "sdk-B", "compiler": "clang-A"}):
            second = cache.Builder(args)
        with patch.object(cache, "toolchain", return_value={"sdk": "sdk-A", "compiler": "clang-B"}):
            third = cache.Builder(args)
        self.assertNotEqual(first.generation(), second.generation())
        self.assertNotEqual(first.generation(), third.generation())
        self.assertNotEqual(cache.fingerprint(first.inputs["arm64"][0]), cache.fingerprint(first.inputs["x86_64"][0]))
        with patch.object(cache, "SSL_FLAGS", ["changed-configure-parameter"]), patch.object(cache, "toolchain", return_value={"sdk": "sdk-A", "compiler": "clang-A"}):
            self.assertNotEqual(first.generation(), cache.Builder(args).generation())

    def testPinnedSourceDigestRejectsBadArchiveWithoutMutation(self):
        archive = self.root / "source.tar.gz"
        archive.write_bytes(b"pinned archive bytes")
        expected = hashlib.sha256(archive.read_bytes()).hexdigest()
        cache.verify_source(archive, expected)
        archive.write_bytes(b"changed archive")
        with self.assertRaises(ValueError):
            cache.verify_source(archive, expected)
        self.assertEqual(archive.read_bytes(), b"changed archive")

    def testMissingOrWrongArchitectureBlocksMerge(self):
        with patch.object(cache, "run", return_value="arm64"):
            cache.check_arch(self.root / "lib/fake.a", ["arm64"])
            with self.assertRaises(ValueError):
                cache.check_arch(self.root / "lib/fake.a", ["x86_64"])
            with self.assertRaises(ValueError):
                cache.check_arch(self.root / "lib/fake.a", cache.ARCHES)
        with patch.object(cache, "run", side_effect=subprocess.CalledProcessError(1, "lipo")):
            with self.assertRaises(subprocess.CalledProcessError):
                cache.check_arch(self.root / "absent.a", ["arm64"])

    def testGeneratedHeaderDifferencesDispatchByArchitectureButOtherDifferencesBlock(self):
        left, right, output = [self.root / name for name in ["arm", "intel", "merged"]]
        for side, value in [(left, b"#define ARCH_VALUE 1\n"), (right, b"#define ARCH_VALUE 2\n")]:
            (side / "openssl").mkdir(parents=True)
            (side / "openssl/configuration.h").write_bytes(value)
            (side / "common.h").write_text("same header")
        cache.merge_headers(left, right, output)
        wrapper = (output / "openssl/configuration.h").read_text()
        self.assertIn("__aarch64__", wrapper); self.assertIn("__x86_64__", wrapper)
        self.assertIn("ARCH_VALUE 1", wrapper); self.assertIn("ARCH_VALUE 2", wrapper)
        (right / "common.h").write_text("wrong header")
        with self.assertRaises(ValueError):
            cache.merge_headers(left, right, self.root / "reject")
        (right / "common.h").unlink()
        with self.assertRaises(ValueError):
            cache.merge_headers(left, right, self.root / "reject-inventory")

    def testWrongVersionHeaderBlocksPublication(self):
        (self.root / "openssl").mkdir()
        (self.root / "libssh2.h").write_text('#define LIBSSH2_VERSION "1.11.1"\n')
        (self.root / "openssl/opensslv.h").write_text('#define OPENSSL_VERSION_STR "3.5.9"\n')
        cache.check_versions(self.root, "1.11.1", "3.5.9")
        for versions in [("old", "3.5.9"), ("1.11.1", "old")]:
            with self.assertRaises(ValueError):
                cache.check_versions(self.root, *versions)

    def testCheckDoesNotDownloadCompileOrCreateRoot(self):
        absent = self.root / "must-stay-absent"
        args = argparse.Namespace(root=str(absent), ssh_version="1.11.1", ssl_version="3.5.9", ssh_sha="pin", ssl_sha="pin")
        with patch.object(cache, "toolchain", return_value={"sdk": "fixture-sdk"}):
            builder = cache.Builder(args)
        with patch.object(cache, "fetch", side_effect=AssertionError("download")), patch.object(cache, "run", side_effect=AssertionError("compile")):
            with self.assertRaises(ValueError):
                builder.check()
        self.assertFalse(absent.exists())

    def testRunWrapperChecksManifestEvenWhenOldLibraryExistsAndBuildsOnlyOnMismatch(self):
        origin = Path(__file__).with_name("build_and_run.sh")
        pin_script = Path(__file__).with_name("build_secure_dependencies.sh")
        pins_before = pin_script.read_bytes()
        for matched in [False, True]:
            root = self.root / ("matched" if matched else "mismatched")
            (root / "script").mkdir(parents=True)
            old = root / ".build/secure-deps/universal/lib/libssh2.a"
            old.parent.mkdir(parents=True); old.write_bytes(b"old library without valid manifest")
            wrapper = root / "script/build_and_run.sh"; shutil.copyfile(origin, wrapper)
            log = root / "calls"
            build = root / "script/build_secure_dependencies.sh"
            build.write_text('#!/bin/bash\necho "${1:-build}" >> "$FIXTURE_CALLS"\nif [[ "${1:-}" == --check ]]; then exit "$FIXTURE_CHECK_CODE"; fi\nexit 0\n')
            build.chmod(0o755)
            fake_bin = root / "bin"; fake_bin.mkdir()
            for name, status in [("pkill", 0), ("xcodebuild", 27)]:
                tool = fake_bin / name; tool.write_text("#!/bin/bash\nexit " + str(status) + "\n"); tool.chmod(0o755)
            env = dict(os.environ, PATH=str(fake_bin) + ":/usr/bin:/bin", FIXTURE_CALLS=str(log), FIXTURE_CHECK_CODE="0" if matched else "1")
            result = subprocess.run(["/bin/bash", str(wrapper), "--verify"], env=env, capture_output=True)
            # Stops at the fake Xcode boundary, never pkills/launches the real application.
            self.assertEqual(result.returncode, 27, result.stderr)
            self.assertEqual(log.read_text().splitlines(), ["--check"] if matched else ["--check", "build"])
            self.assertEqual(old.read_bytes(), b"old library without valid manifest")
        self.assertEqual(pin_script.read_bytes(), pins_before)

    def testGenerationPublicationPreservesOldDirectoryAndSwitchesOnePointer(self):
        old = self.root / "universal"
        old.mkdir(); (old / "old.a").write_bytes(b"old artifact")
        generation = self.root / "cache/universal/key"
        generation.mkdir(parents=True); (generation / "licenses").mkdir()
        cache.activate(self.root, generation)
        self.assertEqual((self.root / "universal").resolve(), generation.resolve())
        self.assertTrue(list(self.root.glob("legacy-universal-*/old.a")))
        self.assertEqual((self.root / "licenses").resolve(), (generation / "licenses").resolve())


if __name__ == "__main__":
    unittest.main(verbosity=2)
