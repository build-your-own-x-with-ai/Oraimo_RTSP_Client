import socket, struct, subprocess, threading, time
def listen(port, path, stop):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    s.bind(("127.0.0.1", port)); s.settimeout(0.5)
    p = []
    while not stop.is_set():
        try: p.append(s.recv(65535))
        except socket.timeout: pass
    with open(path, "wb") as f:
        for x in p: f.write(struct.pack(">I", len(x))); f.write(x)
    print(f"{path}: {len(p)} packets", flush=True)
stop = threading.Event()
t = threading.Thread(target=listen, args=(25000, "audio_pcma.rtp", stop)); t.start()
time.sleep(0.3)
subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-i","/tmp/rtsp_test.mp4",
  "-t","6","-map","0:a","-c:a","pcm_alaw","-ar","8000","-ac","1",
  "-f","rtp","-sdp_file","audio_pcma.sdp","rtp://127.0.0.1:25000"], check=True)
time.sleep(0.8); stop.set(); t.join()
print(open("audio_pcma.sdp").read())
