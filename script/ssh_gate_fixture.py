#!/usr/bin/env python3
"""Disposable SSH handshake/cancellation gate on localhost; no account authentication."""
import socket, threading, time, subprocess
from pathlib import Path
import paramiko
key=paramiko.RSAKey.generate(2048)
def serve(listener, stall):
    while True:
        client,_=listener.accept()
        def session(client):
            if stall:
                time.sleep(2);client.close();return
            transport=paramiko.Transport(client);transport.add_server_key(key)
            try:
                transport.start_server(server=paramiko.ServerInterface())
                time.sleep(.3)
            except (EOFError,OSError,paramiko.SSHException): pass
            finally: transport.close()
        threading.Thread(target=session,args=(client,),daemon=True).start()
listeners=[]
for stall in (False,True):
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listeners.append(listener)
    threading.Thread(target=serve,args=(listener,stall),daemon=True).start()
root=Path(__file__).resolve().parent.parent
for arch in ('arm64','x86_64'):
    executable=root/'.build/secure-deps'/('ssh-probe-'+arch+'.app')/'Contents/MacOS/ssh-probe'
    for index,listener in enumerate(listeners):
        command=[str(executable),'127.0.0.1',str(listener.getsockname()[1])]+(['cancel'] if index else [])
        result=subprocess.run(command,capture_output=True,text=True)
        print(result.stderr,flush=True)
        result.check_returncode()
        print(arch,'cancel' if index else 'handshake',result.stdout.strip(),flush=True)
