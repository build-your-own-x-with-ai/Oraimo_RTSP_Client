import socket, struct, subprocess, sys, threading, time
# 用 ffmpeg 生成真实的 RFC 6184 / 3640 打包，抓下来给测试服务器回放。
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
tv = threading.Thread(target=listen, args=(23000, "video.rtp", stop))
ta = threading.Thread(target=listen, args=(23002, "audio.rtp", stop))
tv.start(); ta.start(); time.sleep(0.3)
subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-i","/tmp/rtsp_test.mp4",
    "-t","6","-map","0:v","-c:v","copy","-f","rtp","-sdp_file","video.sdp",
    "rtp://127.0.0.1:23000"], check=True)
subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-i","/tmp/rtsp_test.mp4",
    "-t","6","-map","0:a","-c:a","copy","-f","rtp","-sdp_file","audio.sdp",
    "rtp://127.0.0.1:23002"], check=True)
time.sleep(0.8); stop.set(); tv.join(); ta.join()
print("--- video.sdp ---"); print(open("video.sdp").read())
print("--- audio.sdp ---"); print(open("audio.sdp").read())
