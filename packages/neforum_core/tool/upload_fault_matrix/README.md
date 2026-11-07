# Upload fault matrix

A manual test lane, Windows only. It runs the real client (`MastodonAdapter`, `NeforumHttp`, `package:http`'s `IOClient`) over real sockets against a local fake Mastodon server, through each way a connection can end, and checks how the run ended.

It is not part of `dart test`: it takes minutes, its results depend on the Windows TCP stack, and no CI job runs it. Run it after a change to `NeforumHttp` or to Mastodon's upload path.

Nothing leaves the machine. The server listens on loopback and no account or token is used.

## Run it

From `packages/neforum_core`:

```
dart compile exe tool/upload_fault_matrix/run_matrix.dart -o %TEMP%\matrix.exe
%TEMP%\matrix.exe
```

Options:

| Option | What it does |
|---|---|
| `--repeat N` | Runs every scenario N times |
| `--only a,b` | Runs only the named scenarios or Toxiproxy cases |
| `--certs DIR` | Also runs every scenario over TLS. `DIR` holds a self-signed `cert.pem` and `key.pem` for `localhost` |
| `--toxiproxy PATH` | Adds the Toxiproxy lane. `PATH` is `toxiproxy-server-windows-amd64.exe` from https://github.com/Shopify/toxiproxy/releases. Port 8474 must be free |
| `--out FILE` | Writes one JSON object per run |

The exit code is 0 only when every run passed. Keep the Toxiproxy binary and any output outside the repo.

## What passing means

Every line shows the media POSTs, the status POSTs and the posts on the server, then what each failed try reported.

- A scenario that ends well has exactly 1 post on the server and exactly 1 status POST. The one exception is `status_answer_lost`: the answer to the status itself is lost, so the client sends it again with the same `Idempotency-Key`, and the fake keeps one post, as Mastodon does.
- A scenario that fault never clears has 0 status POSTs, a message in plain words, and the byte count in the details.
- No message contains an errno, a Dart type name or "Write failed".

## Which error comes from what

On Windows the error tells you how the far side ended the connection, not who did it.

| What reaches the client while it is still writing | Error |
|---|---|
| FIN, then RST when its next data arrives | 10053, usually "Write failed" |
| RST with no FIN first | 10054 |
| FIN after it has finished writing | "Connection closed before full header was received" |

Which of these a close produces depends on the closing side's receive queue. With unread bytes queued, Windows sends RST straight away. With an empty queue it sends FIN, and the RST follows only when more data arrives. So a sender slower than the reader, which is what a slow uplink is, gets 10053, and a sender ahead of the reader gets 10054.

That is why the same fault can show either error between runs, and why the client must never depend on the code.

## Limits of this lane

- Dart cannot set `SO_RCVBUF` on a listening socket, and without it Windows lets a sender get about 2.7 MB ahead on loopback. So the file here is 8 MiB, the rate is 2 MB/s and not the 1 Mbit/s the bug was seen on, and the server closes after 128 KiB. A smaller file would finish writing before the close, and every run would read as "Connection closed before full header".
- Toxiproxy closes both directions as soon as either side ends, so it never passes on a half-closed connection. The `paced+` cases put the local paced proxy in front of it to make a sender slower than Toxiproxy reads. What the client sees in those cases is the paced proxy's relay of what Toxiproxy did.
- The early answer itself is not read. dart:io loses a response that arrives before the body has gone out, so `always_413_over_limit` passes through the size probe and not through the 413.
- Local connection deletion (`SetTcpEntry`, 10054 in the research runs) is not ported. It needs FFI, and it is the same class to the client as a plain RST.
