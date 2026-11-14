# Scheduling a post

The schedule sheet opens from the composer's Schedule button and from **Reschedule** in the queue. Pick a quick time, a day and time, or a random time, then press **Schedule**. In the composer, that sets the time, and the composer's own Schedule button then schedules the post.

## A random time

**Pick a random time** draws one minute from a range:

| Range | From | To |
|---|---|---|
| Next 24 hours, 7, 30, 90 or 365 days | 15 minutes from now | That long from now |
| Custom | The start of the first day you pick, or 15 minutes from now if that is later | The end of the last day you pick, or 365 days from now if that is sooner |

The sheet states the range in words. Year, month, day, hour and minute are all random inside it.

- **Nothing happens until you press Schedule.** Drawing, **Try another** and **Cancel** leave your post as it was. There is no limit on **Try another**.
- **Different time per network** draws one time for each account, each with its own button to draw again. A network that already has the post keeps its time.
- **Every minute that really exists is equally likely.** The draw is over moments in time, not over dates and clock readings. A skipped hour in spring can never come up. An hour that happens twice in autumn gets twice the chance, because it lasts twice as long. Feb 29 counts as one ordinary day.
- **The exact moment is what gets saved.** When a clock reading happens twice that day, the sheet says which of the two this is, by time zone name, and reopening the sheet keeps it.

## What the sheet tells you

The lines under the time are worked out for that time, from the same check NEFORUM uses when it hands the post over. None of them stop you scheduling.

| Line | When |
|---|---|
| NEFORUM hands this post to the network, which publishes it even if this device is off | The network holds posts, this time is inside its limits, and **Let platforms hold scheduled posts** is on |
| The network's own limit, in its words | The time is too soon or too far ahead for that network to hold, so it stays on this device |
| What this device has to do | The post waits on this device: keep NEFORUM running on a computer, background posting on Android, a **Publish now** notification on iPhone and iPad |
| More than 30 days away | The post waits on this device for that long |
| The sign-in ends first | The post waits on this device and the sign-in ends on or before its time. When a post through it would renew it, the line says so |
| X stops accepting this way of signing in | X keys, with a time after the date X announced |
| Needs reconnecting, or refused the sign-in | The sign-in has ended, or the network refused it last time |
| Lands at night and needs you to tap | A hand-off, or a post waiting on an iPhone or iPad, between 23:00 and 07:00 |

Sign-in dates come from a status file kept on each device. The sheet reads no keys, so it never waits on the keychain.

## Times that have passed

A time under one minute ahead, or already past, is refused: it would go out at once. The sheet will not confirm one, and the composer's Schedule button says the time has passed and offers to pick a new one, with nothing saved. A draft can hold an old time for as long as it stays open, which is why both check.

## Clock changes

- **Tomorrow morning** and **Next Monday** are worked out on the calendar, so they stay right on a day of 23 or 25 hours.
- A day and time the clocks skip shows the real time it becomes and says so.
- A move to another time zone keeps the moment and the display follows it.

## Publishing order

When a post goes out, NEFORUM posts to its networks one after another, in your publishing order: the accounts that post automatically first, then the hand-offs, which wait for you. Change it in **Settings > Posting > Publishing order**, or in the composer: the order button beside **All**, **Automatic only** and **None**, or **Publishing order** under the post on a phone. Drag an account by its handle to move it.

- The order that counts is the one you have when the post goes out, not the one you had when you scheduled it. Background posting on Android and iPhone follows it too.
- A hand-off always comes after every automatic account, wherever it is in the list.
- An account you connect later goes to the end of its group until you move it.
- The order syncs with your other settings.
- Activity and the progress sheet list the networks in the same order.
