import socket, struct, subprocess, threading, time
def listen(port, path, stop):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    s.bind(("127.0.0.1", port)); s.settimeout(0.5)
    pkts = []
    while not stop.is_set():
        try: pkts.append(s.recv(65535))
        except socket.timeout: pass
    with open(path, "wb") as f:
        for p in pkts: f.write(struct.pack(">I", len(p))); f.write(p)
    print(f"{path}: {len(pkts)} packets", flush=True)
stop = threading.Event()
t = threading.Thread(target=listen, args=(24000, "video265.rtp", stop)); t.start()
time.sleep(0.3)
subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-i","/tmp/rtsp_test.mp4",
  "-t","4","-map","0:v","-c:v","libx265","-preset","ultrafast","-x265-params","log-level=none:keyint=25",
  "-f","rtp","-sdp_file","video265.sdp","rtp://127.0.0.1:24000"], check=True)
time.sleep(0.8); stop.set(); t.join()
print(open("video265.sdp").read())
