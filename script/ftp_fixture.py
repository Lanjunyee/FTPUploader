#!/usr/bin/env python3
"""Disposable localhost FTP fixture; Python standard library only."""
import argparse
import json
import posixpath
import signal
import socket
import socketserver
import ssl
import tempfile
import threading
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=0)
parser.add_argument('--root', type=Path)
parser.add_argument('--scenario', choices=['normal', 'no-mlsd', 'deny-login', 'deny-list', 'malformed', 'legacy', 'slow-list', 'slow-greeting', 'ascii-root', 'empty-root', 'legacy-ascii-root', 'legacy-empty-root', 'deny-root', 'legacy-deny-root', 'account-only', 'echo-password'], default='normal')
parser.add_argument('--delay', type=float, default=2)
parser.add_argument('--tls', choices=['explicit','implicit'])
parser.add_argument('--cert', type=Path)
parser.add_argument('--key', type=Path)
parser.add_argument('--fail-data-tls', action='store_true')
args = parser.parse_args()
tls_context = None
if args.tls:
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.load_cert_chain(str(args.cert), str(args.key))
temporary = tempfile.TemporaryDirectory(prefix='ftp-fixture-') if args.root is None else None
root = (Path(temporary.name) if temporary else args.root).resolve()
root.mkdir(parents=True, exist_ok=True)
for name in ['共享 资料%#', '空目录', '拒绝访问', '拒绝写入', '空间不足', '等待确认', '最终拒绝', '最终断开', '中断', '超时', 'DOS', '旧格式']:
    (root / name).mkdir(exist_ok=True)
for name in ['账户资料', '访客资料']:
    (root / name).mkdir(exist_ok=True)
(root / '共享 资料%#' / '项目文件').mkdir(exist_ok=True)
(root / '中文 空格%' / '第二层').mkdir(parents=True, exist_ok=True)
protected = root / '共享 资料%#' / '已提交.txt'
if not protected.exists():
    protected.write_bytes(b'existing protected submission\n')
command_log = root / '.commands.jsonl'
command_log.touch(exist_ok=True)
log_lock = threading.Lock()
encoding = 'gb18030' if args.scenario.startswith('legacy') else 'utf-8'


class Handler(socketserver.StreamRequestHandler):
    def setup(self):
        if args.tls == 'implicit':
            self.request = tls_context.wrap_socket(self.request, server_side=True)
        super().setup()
        self.protected = False
        self.request.settimeout(20)
        self.cwd = '/'
        self.logged_in = False
        self.user = None
        self.data_listener = None

    def reply(self, code, text):
        self.wfile.write(f'{code} {text}\r\n'.encode('ascii'))
        self.wfile.flush()

    def log(self, command, argument):
        record = {'command': command, 'argument': '[redacted]' if command == 'PASS' else argument, 'cwd': self.cwd, 'control_tls': 'yes' if isinstance(self.request, ssl.SSLSocket) else 'no'}
        with log_lock:
            with command_log.open('a') as output:
                output.write(json.dumps(record, ensure_ascii=False) + '\n')

    def path(self, argument):
        relative = posixpath.normpath(posixpath.join(self.cwd, argument))
        candidate = (root / relative.lstrip('/')).resolve()
        if candidate != root and root not in candidate.parents:
            raise ValueError('outside fixture root')
        return relative, candidate

    def passive(self, extended):
        self.close_data()
        self.data_listener = socket.socket()
        self.data_listener.bind(('127.0.0.1', 0))
        self.data_listener.listen(1)
        self.data_listener.settimeout(5)
        port = self.data_listener.getsockname()[1]
        if extended:
            self.reply(229, f'Entering Extended Passive Mode (|||{port}|)')
        else:
            self.reply(227, f'Entering Passive Mode (127,0,0,1,{port // 256},{port % 256})')

    def close_data(self):
        if self.data_listener:
            self.data_listener.close()
            self.data_listener = None

    def data_socket(self):
        if not self.data_listener:
            self.reply(425, 'Use EPSV or PASV first')
            return None
        self.reply(150, 'Opening binary data connection')
        connection, _ = self.data_listener.accept()
        connection.settimeout(5)
        self.close_data()
        if self.protected:
            if args.fail_data_tls:
                connection.close()
                raise OSError('deliberate data TLS failure')
            connection = tls_context.wrap_socket(connection, server_side=True)
        with log_lock:
            with command_log.open('a') as output:
                output.write(json.dumps({'command':'DATA', 'argument':'', 'cwd':self.cwd,
                                         'data_tls':'yes' if isinstance(connection, ssl.SSLSocket) else 'no'})+'\n')
        return connection

    def listing(self, command):
        if args.scenario == 'deny-list' or (self.cwd == '/' and args.scenario.endswith('deny-root')):
            self.reply(550, 'Directory access denied')
            self.close_data()
            return
        if command == 'MLSD' and (args.scenario == 'no-mlsd' or self.cwd == '/旧格式' or self.cwd == '/DOS'):
            self.reply(502, 'MLSD not supported')
            self.close_data()
            return
        if args.scenario == 'slow-list':
            time.sleep(args.delay)
        directory = self.path('.')[1]
        rows = []
        for entry in sorted(directory.iterdir()):
            if entry.name.startswith('.'):
                continue
            if entry.name == '账户资料' and self.user != 'member':
                continue
            if entry.name == '访客资料' and self.user != 'guest':
                continue
            is_dir = entry.is_dir()
            size = 0 if is_dir else entry.stat().st_size
            if command == 'MLSD':
                rows.append(f'type={"dir" if is_dir else "file"};size={size};modify=20261003000000; {entry.name}')
            elif self.cwd == '/DOS':
                kind = '<DIR>' if is_dir else str(size)
                rows.append(f'10-03-26  12:00PM       {kind}          {entry.name}')
            else:
                kind = 'd' if is_dir else '-'
                rows.append(f'{kind}rwxr-xr-x 1 ftp ftp {size} Oct 03 12:00 {entry.name}')
        if self.cwd == '/' and args.scenario.endswith('empty-root'):
            rows = []
        elif self.cwd == '/' and args.scenario.endswith('ascii-root'):
            rows = [row for row in rows if row.isascii()]
        if args.scenario == 'malformed':
            rows = ['this is not a supported directory listing']
        body = ('\r\n'.join(rows) + ('\r\n' if rows else '')).encode(encoding)
        connection = self.data_socket()
        if connection:
            with connection:
                connection.sendall(body)
                if isinstance(connection, ssl.SSLSocket): connection.unwrap().close()
            self.reply(226, 'Directory transfer complete')

    def store(self, argument):
        _, destination = self.path(argument)
        if self.cwd == '/拒绝写入' or destination.exists():
            self.reply(553, 'New files only; existing files are protected')
            self.close_data()
            return True
        if self.cwd == '/空间不足':
            self.reply(552, 'Insufficient storage')
            self.close_data()
            return True
        if not destination.parent.is_dir():
            self.reply(550, 'Target directory does not exist')
            self.close_data()
            return True
        connection = self.data_socket()
        if connection is None:
            return True
        with connection, destination.open('xb') as output:
            if self.cwd == '/超时':
                time.sleep(args.delay)
                return False
            while True:
                data = connection.recv(65536)
                if not data:
                    if isinstance(connection, ssl.SSLSocket): connection.unwrap().close()
                    break
                output.write(data)
                if self.cwd == '/中断':
                    return False
        if self.cwd == '/等待确认':
            time.sleep(args.delay)
        if self.cwd == '/最终拒绝':
            self.reply(552, 'Rejected after receiving data')
        elif self.cwd == '/最终断开':
            return False
        else:
            self.reply(226, 'Upload complete')
        return True

    def retrieve(self, argument):
        _, source = self.path(argument)
        if not source.is_file() or source.name == 'denied.bin':
            self.reply(550, 'File unavailable')
            self.close_data()
            return True
        connection = self.data_socket()
        if connection is None: return True
        with connection, source.open('rb') as stream:
            while True:
                data = stream.read(32768)
                if not data: break
                connection.sendall(data)
                if source.name == 'disconnect.bin': return False
                if source.name == 'slow.bin': time.sleep(args.delay)
            if isinstance(connection, ssl.SSLSocket): connection.unwrap().close()
        if source.name == 'delay.bin': time.sleep(args.delay)
        if source.name == 'reject.bin': self.reply(552, 'Rejected after sending data')
        else: self.reply(226, 'Download complete')
        return True

    def handle(self):
        if args.scenario == 'slow-greeting':
            time.sleep(args.delay)
        self.reply(220, 'FTP test fixture')
        try:
            while True:
                raw = self.rfile.readline(8192)
                if not raw:
                    break
                line = raw.rstrip(b'\r\n').decode(encoding)
                command, _, argument = line.partition(' ')
                command = command.upper()
                self.log(command, argument)
                if command == 'AUTH':
                    if args.tls == 'explicit' and argument in ['TLS','SSL']:
                        self.reply(234, 'Begin TLS')
                        self.request = tls_context.wrap_socket(self.request, server_side=True)
                        self.rfile = self.request.makefile('rb', self.rbufsize)
                        self.wfile = self.request.makefile('wb', self.wbufsize)
                    else: self.reply(502, 'TLS unavailable')
                elif command == 'PBSZ': self.reply(200, 'PBSZ accepted')
                elif command == 'PROT':
                    self.protected = argument == 'P'
                    self.reply(200 if self.protected else 534, 'Private data required')
                elif command == 'USER':
                    self.user = argument
                    self.reply(331, 'Password required')
                elif command == 'PASS':
                    accounts = {'member': 'fixture-pass:@ ', 'guest': 'guest-pass', 'empty': ''}
                    self.logged_in = (self.user == 'anonymous' and args.scenario not in ['deny-login', 'account-only', 'echo-password']) or (
                        self.user in accounts and argument == accounts[self.user] and args.scenario != 'echo-password')
                    if args.scenario == 'echo-password':
                        self.reply(530, 'Denied ' + 'x' * 490 + argument + ' end')
                    else:
                        self.reply(230 if self.logged_in else 530, 'Logged in' if self.logged_in else 'Login denied')
                elif command == 'QUIT':
                    self.reply(221, 'Goodbye')
                    break
                elif not self.logged_in:
                    self.reply(530, 'Login required')
                elif command == 'PWD':
                    self.wfile.write(('257 "' + self.cwd.replace('"', '""') + '"\r\n').encode(encoding))
                    self.wfile.flush()
                elif command == 'CWD':
                    path, directory = self.path(argument)
                    if (path == '/拒绝访问' or not directory.is_dir()
                            or (path.startswith('/账户资料') and self.user != 'member')
                            or (path.startswith('/访客资料') and self.user != 'guest')):
                        self.reply(550, 'Directory not accessible')
                    else:
                        self.cwd = path
                        self.reply(250, 'Directory changed')
                elif command == 'EPSV': self.passive(True)
                elif command == 'PASV': self.passive(False)
                elif command in ['MLSD', 'LIST', 'NLST']: self.listing(command)
                elif command == 'RETR':
                    if not self.retrieve(argument): break
                elif command == 'STOR':
                    if not self.store(argument): break
                elif command == 'SIZE':
                    _, file = self.path(argument)
                    self.reply(213, str(file.stat().st_size)) if file.is_file() else self.reply(550, 'No such file')
                elif command == 'FEAT':
                    self.wfile.write(b'211-Features\r\n MLST type*;size*;modify*;\r\n' + (b' UTF8\r\n' if encoding == 'utf-8' else b'') + b'211 End\r\n')
                    self.wfile.flush()
                elif command == 'OPTS': self.reply(200 if encoding == 'utf-8' else 502, 'Option response')
                elif command in ['TYPE', 'NOOP']: self.reply(200, 'OK')
                elif command == 'SYST': self.reply(215, 'UNIX Type: L8')
                else: self.reply(502, 'Command not implemented')
        except (OSError, ValueError, UnicodeError):
            pass
        finally:
            self.close_data()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


server = Server(('127.0.0.1', args.port), Handler)
def stop(*_):
    threading.Thread(target=server.shutdown, daemon=True).start()

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
print(json.dumps({'port': server.server_address[1], 'root': str(root), 'log': str(command_log)}), flush=True)
try:
    server.serve_forever(poll_interval=0.05)
finally:
    server.server_close()
    if temporary:
        temporary.cleanup()
