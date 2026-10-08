#!/usr/bin/env python3
"""Disposable localhost SFTP server for integration tests; requires Paramiko test environment."""
import argparse, base64, json, os, posixpath, signal, socket, stat, tempfile, threading, time
from pathlib import Path
import paramiko
from paramiko.sftp import CMD_CLOSE
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port',type=int,default=0)
parser.add_argument('--scenario',default='normal',choices=['normal','slow-list','slow-upload','delay-close','reject-close','disconnect','deny-login','invalid-utf8'])
parser.add_argument('--delay',type=float,default=2)
args=parser.parse_args()
temporary=tempfile.TemporaryDirectory(prefix='sftp-fixture-');root=Path(temporary.name).resolve()
for directory in ('中文 空格%#','空目录','拒绝访问','拒绝写入','等待确认'):(root/directory).mkdir()
(root/'中文 空格%#'/'已提交.txt').write_bytes(b'protected\n')
key=paramiko.RSAKey.generate(2048)
log=root/'.commands.jsonl';log.touch();lock=threading.Lock()
def record(command,path=''):
    with lock:
        with log.open('a') as out: out.write(json.dumps({'command':command,'path':path},ensure_ascii=False)+'\n')
class Server(paramiko.ServerInterface):
    def __init__(self,transport):self.transport=transport
    def get_allowed_auths(self,username):return 'password'
    def check_auth_password(self,username,password):
        record('AUTH')
        return paramiko.AUTH_SUCCESSFUL if username=='member' and password=='fixture-pass:@ ' and args.scenario!='deny-login' else paramiko.AUTH_FAILED
    def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
class Handle(paramiko.SFTPHandle):
    def stat(self):
        stream=getattr(self,'readfile',None) or getattr(self,'writefile',None)
        return paramiko.SFTPAttributes.from_stat(os.fstat(stream.fileno()))
    def read(self,offset,length):
        if self.path.endswith('/slow.bin'):time.sleep(args.delay)
        result=super().read(offset,length)
        if self.path.endswith('/disconnect.bin'):self.transport.close()
        return result
    def write(self,offset,data):
        if args.scenario=='slow-upload':time.sleep(args.delay)
        result=super().write(offset,data)
        if args.scenario=='disconnect':self.transport.close()
        return result
class Files(paramiko.SFTPServerInterface):
    def __init__(self,server,*args,**kwargs):super().__init__(server,*args,**kwargs);self.transport=server.transport
    def local(self,path):
        candidate=(root/posixpath.normpath('/'+path).lstrip('/')).resolve()
        if candidate!=root and root not in candidate.parents:raise OSError('outside test root')
        return candidate
    def list_folder(self,path):
        record('LIST',path)
        if path=='/拒绝访问':return paramiko.SFTP_PERMISSION_DENIED
        if args.scenario=='slow-list':time.sleep(args.delay)
        try:
            entries=[]
            for child in sorted(self.local(path).iterdir()):
                if child.name.startswith('.'):continue
                attr=paramiko.SFTPAttributes.from_stat(child.stat());attr.filename=child.name
                entries.append(attr)
            if args.scenario=='invalid-utf8':
                attr=paramiko.SFTPAttributes();attr.st_mode=stat.S_IFREG|0o644;attr.filename=b'bad\xff';entries=[attr]
            return entries
        except OSError as error:
            record('LIST_ERROR',str(error));return paramiko.SFTP_NO_SUCH_FILE
    def stat(self,path):
        try:return paramiko.SFTPAttributes.from_stat(self.local(path).stat())
        except OSError:return paramiko.SFTP_NO_SUCH_FILE
    lstat=stat
    def open(self,path,flags,attr):
        record('OPEN',path)
        if path.endswith('/denied.bin') or (flags & (os.O_WRONLY|os.O_RDWR) and (path.startswith('/拒绝写入/') or path.endswith('/已提交.txt'))):return paramiko.SFTP_PERMISSION_DENIED
        try:
            fd=os.open(self.local(path),flags,0o644)
            handle=Handle(flags);handle.transport=self.transport;handle.path=path
            if flags & (os.O_WRONLY|os.O_RDWR):handle.writefile=os.fdopen(fd,'wb')
            else:handle.readfile=os.fdopen(fd,'rb')
            return handle
        except OSError:return paramiko.SFTP_FAILURE
class Subsystem(paramiko.SFTPServer):
    def _process(self,t,request_number,msg):
        if t==CMD_CLOSE:
            # Directory closes also pass here; inject only for file handles.
            clone=paramiko.Message(msg.get_remainder());handle=clone.get_binary()
            if handle in self.file_table:
                record('CLOSE')
                if args.scenario=='delay-close' or self.file_table[handle].path.startswith('/等待确认/'):time.sleep(args.delay)
                if args.scenario=='reject-close':
                    self.file_table.pop(handle).close();self._send_status(request_number,paramiko.SFTP_FAILURE);return
        super()._process(t,request_number,msg)
listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(('127.0.0.1',args.port));listener.listen();listener.settimeout(.2)
stop=threading.Event();transports=[]
def session(client):
    transport=paramiko.Transport(client);transports.append(transport);transport.add_server_key(key)
    transport.set_subsystem_handler('sftp',Subsystem,Files)
    try:
        transport.start_server(server=Server(transport))
        while transport.is_active() and not stop.is_set():time.sleep(.05)
    except (EOFError,OSError,paramiko.SSHException):pass
    finally:transport.close()
def shutdown(*_):stop.set()
signal.signal(signal.SIGTERM,shutdown);signal.signal(signal.SIGINT,shutdown)
print(json.dumps({'port':listener.getsockname()[1],'root':str(root),'log':str(log),'key':base64.b64encode(key.asbytes()).decode()}),flush=True)
try:
    while not stop.is_set():
        try:client,_=listener.accept()
        except socket.timeout:continue
        threading.Thread(target=session,args=(client,),daemon=True).start()
finally:
    listener.close()
    for transport in transports:transport.close()
    temporary.cleanup()
