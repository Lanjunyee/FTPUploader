#!/usr/bin/env python3
"""Owner-local, content-verified static dependency cache; no unpinned downloads."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

ARCHES = ("arm64", "x86_64")
SCHEMA = 1
GENERATED_HEADERS = {"openssl/configuration.h", "openssl/opensslconf.h"}
SSL_FLAGS = ["no-shared", "no-tests", "no-module", "no-engine", "no-legacy", "--libdir=lib", "-mmacosx-version-min=13.0"]
SSH_FLAGS = ["CMAKE_BUILD_TYPE=Release", "CMAKE_OSX_DEPLOYMENT_TARGET=13.0", "CRYPTO_BACKEND=OpenSSL", "OPENSSL_USE_STATIC_LIBS=ON", "BUILD_SHARED_LIBS=OFF", "BUILD_EXAMPLES=OFF", "BUILD_TESTING=OFF", "ENABLE_ZLIB_COMPRESSION=OFF"]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def fingerprint(inputs):
    return hashlib.sha256(canonical(inputs)).hexdigest()


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def tree(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("Symlink in cache artifact: " + str(path))
        if path.is_file() and path != root / "manifest.json":
            result[str(path.relative_to(root))] = digest(path)
    return result


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    try:
        with open(temporary, "xb") as output:
            output.write(canonical(value) + b"\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def complete(root, inputs):
    artifacts = tree(root)
    if not artifacts:
        raise ValueError("Empty artifact cannot be completed")
    atomic_json(root / "manifest.json", {"schema": SCHEMA, "fingerprint": fingerprint(inputs), "inputs": inputs, "artifacts": artifacts})


def matches(root, inputs):
    try:
        manifest = json.loads((root / "manifest.json").read_text())
        return (manifest["schema"] == SCHEMA and manifest["inputs"] == inputs
                and manifest["fingerprint"] == fingerprint(inputs)
                and bool(manifest["artifacts"]) and manifest["artifacts"] == tree(root))
    except (OSError, ValueError, KeyError, TypeError):
        return False


def run(*arguments, cwd=None, capture=False):
    value = subprocess.run([str(a) for a in arguments], cwd=cwd, check=True,
                           stdout=subprocess.PIPE if capture else None, stderr=subprocess.STDOUT if capture else None)
    return value.stdout.decode().strip() if capture else None


def toolchain():
    sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path", capture=True)
    cc = run("xcrun", "--find", "clang", capture=True)
    cxx = run("xcrun", "--find", "clang++", capture=True)
    settings = Path(sdk) / "SDKSettings.json"
    if not settings.exists():
        settings = Path(sdk) / "SDKSettings.plist"
    tools = {"sdk": sdk, "sdk_version": run("xcrun", "--show-sdk-version", capture=True),
             "sdk_settings_sha256": digest(settings), "cc": cc, "cxx": cxx,
             "compiler": run(cc, "--version", capture=True), "xcode": run("xcodebuild", "-version", capture=True),
             "linker": run("xcrun", "ld", "-version_details", capture=True),
             "archiver": {"path": run("xcrun", "--find", "ar", capture=True),
                          "sha256": digest(run("xcrun", "--find", "ar", capture=True))}}
    for name, argument in [("cmake", "--version"), ("perl", "-v"), ("make", "--version")]:
        tools[name] = {"path": shutil.which(name), "version": run(name, argument, capture=True)}
    return tools


def verify_source(path, expected):
    if not path.is_file() or digest(path) != expected:
        raise ValueError("Pinned source SHA256 mismatch: " + str(path))


def fetch(path, url, expected):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".download-" + uuid.uuid4().hex)
        try:
            run("curl", "--fail", "--location", "--max-time", "120", url, "-o", temporary)
            verify_source(temporary, expected)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    verify_source(path, expected)


def extract(archive, destination):
    with tarfile.open(archive, "r:gz") as source:
        # Pinned archives only. Also reject escaping names/links before extraction.
        base = destination.resolve()
        for member in source.getmembers():
            target = (destination / member.name).resolve()
            if base not in target.parents or member.issym() or member.islnk():
                raise ValueError("Unsafe archive member: " + member.name)
        source.extractall(destination)


def check_arch(library, expected):
    actual = set(run("xcrun", "lipo", "-archs", library, capture=True).split())
    if actual != set(expected):
        raise ValueError("Wrong library architectures: " + str(library) + " " + str(sorted(actual)))


def check_library_version(library, dependency, version):
    lines = run("strings", library, capture=True).splitlines()
    expected = version if dependency == "libssh2" else "OpenSSL " + version + " "
    valid = expected in lines if dependency == "libssh2" else any(line.startswith(expected) for line in lines)
    if not valid:
        raise ValueError("Static archive version marker mismatch: " + str(library))


def merge_headers(left, right, output):
    a = {str(p.relative_to(left)): p for p in left.rglob("*") if p.is_file()}
    b = {str(p.relative_to(right)): p for p in right.rglob("*") if p.is_file()}
    if set(a) != set(b):
        raise ValueError("Architecture header inventories differ")
    for name in sorted(a):
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if a[name].read_bytes() == b[name].read_bytes():
            shutil.copyfile(a[name], destination)
        elif name in GENERATED_HEADERS:
            destination.write_bytes(b"#if defined(__aarch64__) || defined(__arm64__)\n" + a[name].read_bytes()
                                    + b"\n#elif defined(__x86_64__)\n" + b[name].read_bytes()
                                    + b"\n#else\n#error Unsupported dependency architecture\n#endif\n")
        else:
            raise ValueError("Unexpected non-generated header difference: " + name)


def check_versions(include, ssh, ssl):
    import re
    ssh_header = (include / "libssh2.h").read_text()
    ssl_header = (include / "openssl/opensslv.h").read_text()
    for text, macro, version in [(ssh_header, "LIBSSH2_VERSION", ssh), (ssl_header, "OPENSSL_VERSION_STR", ssl)]:
        found = re.search(r'^\s*#\s*define\s+' + macro + r'\s+"([^"\n]+)"', text, re.MULTILINE)
        if not found or found.group(1) != version:
            raise ValueError("Header version mismatch: " + macro)


def publish(stage, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        # Preserve a corrupt/obsolete generation, never merge into it.
        os.replace(destination, destination.with_name(destination.name + ".invalid-" + uuid.uuid4().hex))
    os.replace(stage, destination)


def activate(root, generation):
    link = root / (".universal-" + uuid.uuid4().hex)
    link.symlink_to(os.path.relpath(generation, root), target_is_directory=True)
    target = root / "universal"
    if target.exists() and not target.is_symlink():
        os.replace(target, root / ("legacy-universal-" + uuid.uuid4().hex))
    os.replace(link, target)
    # Existing license consumers keep their stable path too.
    licenses = root / "licenses"
    if licenses.exists() and not licenses.is_symlink():
        os.replace(licenses, root / ("legacy-licenses-" + uuid.uuid4().hex))
    temporary = root / (".licenses-" + uuid.uuid4().hex)
    temporary.symlink_to("universal/licenses", target_is_directory=True)
    os.replace(temporary, licenses)


class Builder:
    def __init__(self, args):
        self.args = args
        self.root = Path(args.root).resolve()
        self.tools = toolchain()
        # Recipe identity includes both scripts and probe; edits invalidate old evidence.
        self.recipe = {name: digest(Path(__file__).with_name(name)) for name in
                       ["secure_dependency_cache.py", "build_secure_dependencies.sh", "dependency_version_probe.c"]}
        self.inputs = {}
        for arch in ARCHES:
            ssl = {"recipe": self.recipe, "toolchain": self.tools, "architecture": arch,
                   "deployment_target": "13.0", "dependency": "openssl", "version": args.ssl_version,
                   "sha256": args.ssl_sha, "parameters": SSL_FLAGS, "root": str(self.root)}
            ssh = {"recipe": self.recipe, "toolchain": self.tools, "architecture": arch,
                   "deployment_target": "13.0", "dependency": "libssh2", "version": args.ssh_version,
                   "sha256": args.ssh_sha, "parameters": SSH_FLAGS, "openssl_fingerprint": fingerprint(ssl), "root": str(self.root)}
            self.inputs[arch] = (ssl, ssh)
        self.universal_inputs = {"recipe": self.recipe, "architectures": list(ARCHES),
                                 "inputs": {arch: [fingerprint(i) for i in self.inputs[arch]] for arch in ARCHES}}

    def location(self, inputs):
        return self.root / "cache" / inputs["dependency"] / inputs["architecture"] / fingerprint(inputs)

    def generation(self):
        return self.root / "cache/universal" / fingerprint(self.universal_inputs)

    def sources(self, download=False):
        a = self.args
        specs = [("libssh2-" + a.ssh_version + ".release.tar.gz", a.ssh_sha,
                  "https://github.com/libssh2/libssh2/releases/download/libssh2-" + a.ssh_version + "/libssh2-" + a.ssh_version + ".tar.gz"),
                 ("openssl-" + a.ssl_version + ".tar.gz", a.ssl_sha,
                  "https://github.com/openssl/openssl/releases/download/openssl-" + a.ssl_version + "/openssl-" + a.ssl_version + ".tar.gz")]
        for name, sha, url in specs:
            path = self.root / "sources" / name
            if download:
                fetch(path, url, sha)
            elif path.exists():
                verify_source(path, sha)

    def check(self):
        self.sources()
        for arch in ARCHES:
            for inputs in self.inputs[arch]:
                if not matches(self.location(inputs), inputs):
                    raise ValueError("Missing/mismatched completed cache: " + inputs["dependency"] + " " + arch)
        generation = self.generation()
        if not matches(generation, self.universal_inputs) or (self.root / "universal").resolve() != generation:
            raise ValueError("Universal cache manifest or active generation mismatch")
        check_versions(generation / "include", self.args.ssh_version, self.args.ssl_version)
        for name, dependency, version in [("libssh2.a", "libssh2", self.args.ssh_version), ("libcrypto.a", "openssl", self.args.ssl_version)]:
            check_arch(generation / "lib" / name, ARCHES)
            check_library_version(generation / "lib" / name, dependency, version)

    def build_one(self, inputs, archive, openssl=None):
        destination = self.location(inputs)
        if matches(destination, inputs):
            print("CACHE reuse " + inputs["dependency"] + " " + inputs["architecture"], flush=True)
            return destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=".building-", dir=destination.parent))
        try:
            extract(archive, stage)
            prefix = stage / "install"
            arch = inputs["architecture"]
            if inputs["dependency"] == "openssl":
                source = stage / ("openssl-" + self.args.ssl_version)
                target = "darwin64-arm64-cc" if arch == "arm64" else "darwin64-x86_64-cc"
                run("./Configure", target, *SSL_FLAGS, "--prefix=" + str(prefix), cwd=source)
                run("make", "-j8", "build_libs", cwd=source)
                run("make", "install_dev", cwd=source)
                libraries = ["libcrypto.a", "libssl.a"]
                license_source = source / "LICENSE.txt"
            else:
                source = stage / ("libssh2-" + self.args.ssh_version)
                run("cmake", "-S", source, "-B", stage / "ssh-build", *["-D" + flag for flag in SSH_FLAGS],
                    "-DCMAKE_OSX_ARCHITECTURES=" + arch, "-DCMAKE_OSX_SYSROOT=" + self.tools["sdk"],
                    "-DCMAKE_C_COMPILER=" + self.tools["cc"], "-DCMAKE_INSTALL_PREFIX=" + str(prefix),
                    "-DOPENSSL_ROOT_DIR=" + str(openssl / "install"))
                run("cmake", "--build", stage / "ssh-build", "-j8")
                run("cmake", "--install", stage / "ssh-build")
                libraries = ["libssh2.a"]
                license_source = source / "COPYING"
            for name in libraries:
                check_arch(prefix / "lib" / name, [arch])
            shutil.copyfile(license_source, stage / "LICENSE")
            # Work/source trees are not completed artifacts; keep only install + license.
            for child in list(stage.iterdir()):
                if child.name not in {"install", "LICENSE"}:
                    shutil.rmtree(child) if child.is_dir() else child.unlink()
            complete(stage, inputs)
            publish(stage, destination)
            return destination
        finally:
            if stage.exists():
                shutil.rmtree(stage)

    def probe(self, generation, execute=False):
        check_versions(generation / "include", self.args.ssh_version, self.args.ssl_version)
        source = Path(__file__).with_name("dependency_version_probe.c")
        with tempfile.TemporaryDirectory(prefix="secure-dependency-probe-") as directory:
            for arch in ARCHES:
                binary = Path(directory) / arch
                run(self.tools["cc"], "-arch", arch, "-isysroot", self.tools["sdk"], "-mmacosx-version-min=13.0",
                    "-Werror", "-I" + str(generation / "include"), source,
                    generation / "lib/libssh2.a", generation / "lib/libcrypto.a", "-o", binary)
                check_arch(binary, [arch])
                links = run("otool", "-L", binary, capture=True)
                if any(name in links for name in ["libssh2.", "libcrypto.", "libssl.", "/opt/homebrew/", "/usr/local/"]):
                    raise ValueError("Probe unexpectedly links external crypto/SSH dylib")
                if execute or arch == platform.machine():
                    print("PROBE " + arch + " " + run("/usr/bin/arch", "-" + arch, binary, capture=True), flush=True)
                else:
                    print("PROBE compiled/static " + arch, flush=True)

    def build(self):
        try:
            self.check()
            print("CACHE all inputs and completed artifacts match; no download/build", flush=True)
            return
        except ValueError:
            pass
        self.sources(download=True)
        os.environ.update({"CC": self.tools["cc"], "CXX": self.tools["cxx"], "SDKROOT": self.tools["sdk"]})
        inputs_by_arch = {}
        for arch in ARCHES:
            ssl_inputs, ssh_inputs = self.inputs[arch]
            ssl = self.build_one(ssl_inputs, self.root / "sources" / ("openssl-" + self.args.ssl_version + ".tar.gz"))
            ssh = self.build_one(ssh_inputs, self.root / "sources" / ("libssh2-" + self.args.ssh_version + ".release.tar.gz"), ssl)
            inputs_by_arch[arch] = (ssl, ssh)
        destination = self.generation()
        if not matches(destination, self.universal_inputs):
            destination.parent.mkdir(parents=True, exist_ok=True)
            stage = Path(tempfile.mkdtemp(prefix=".merging-", dir=destination.parent))
            try:
                (stage / "lib").mkdir()
                (stage / "licenses").mkdir()
                for library, index in [("libcrypto.a", 0), ("libssh2.a", 1)]:
                    sides = [inputs_by_arch[arch][index] / "install/lib" / library for arch in ARCHES]
                    for arch, side in zip(ARCHES, sides):
                        check_arch(side, [arch])
                        check_library_version(side, "openssl" if index == 0 else "libssh2",
                                              self.args.ssl_version if index == 0 else self.args.ssh_version)
                    run("xcrun", "lipo", "-create", *sides, "-output", stage / "lib" / library)
                    check_arch(stage / "lib" / library, ARCHES)
                for index in [0, 1]:
                    merge_headers(inputs_by_arch["arm64"][index] / "install/include",
                                  inputs_by_arch["x86_64"][index] / "install/include", stage / "include")
                for index, name in [(0, "OpenSSL-LICENSE.txt"), (1, "libssh2-COPYING")]:
                    left, right = (inputs_by_arch[arch][index] / "LICENSE" for arch in ARCHES)
                    if digest(left) != digest(right):
                        raise ValueError("Architecture license sources differ")
                    shutil.copyfile(left, stage / "licenses" / name)
                self.probe(stage)
                complete(stage, self.universal_inputs)
                publish(stage, destination)
            finally:
                if stage.exists():
                    shutil.rmtree(stage)
        activate(self.root, destination)
        self.check()
        print("CACHE published verified universal generation " + fingerprint(self.universal_inputs), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["build", "check", "verify"])
    for name in ["root", "ssh-version", "ssl-version", "ssh-sha", "ssl-sha"]:
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    # These inherited variables would otherwise alter a build outside its declared key.
    for name in ["CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "ARCHFLAGS", "MAKEFLAGS", "MFLAGS", "CC", "CXX", "AR", "RANLIB", "MACOSX_DEPLOYMENT_TARGET", "SDKROOT", "OPENSSL_CONF", "OPENSSL_MODULES", "CMAKE_PREFIX_PATH", "CMAKE_TOOLCHAIN_FILE", "CMAKE_GENERATOR", "CONFIG_SITE"]:
        os.environ.pop(name, None)
    try:
        builder = Builder(args)
        if args.mode == "build":
            builder.build()
        else:
            builder.check()
            if args.mode == "verify":
                builder.probe(builder.generation(), execute=True)
            else:
                print("CACHE match (read-only; no download/build)")
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print("Dependency verification failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
