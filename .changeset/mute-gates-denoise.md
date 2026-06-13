---
"virtual-headset": minor
---

Suspend the denoiser while muted. On mute, the daemon unlinks the source from the
loopback capture (`pw-link -d`), so the RNNoise filter and raw mic lose their
consumer and suspend to ~0% CPU; the loopback keeps feeding silence into
`Virtual_Headset_Mic`, so the device stays present for the call app. Unmuting
relinks it and the mic resumes in ~16ms (inaudible). This reclaims the ~2-3% the
denoiser otherwise burned during the muted portions of a call (on top of the
passive-loopback change that already idles the chain when no app is capturing).
