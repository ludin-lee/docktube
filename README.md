# DockTube

**English** | [한국어](README.ko.md)

A tiny macOS app that plays YouTube videos (or your own video files) **right inside your Dock icon**.

![DockTube icon](AppIcon.png)

## Download & Install

1. **[Download DockTube.dmg](https://github.com/ludin-lee/docktube/releases/latest/download/DockTube.dmg)**
2. Open `DockTube.dmg` and drag **DockTube** into your **Applications** folder.
3. Launch DockTube from Applications.

Requires macOS 12 (Monterey) or later. Works on both Apple Silicon (M1 and later) and Intel Macs.

### If macOS says the app "can't be opened"

DockTube is a free app without an Apple developer signature, so macOS may block it the first time you open it.

1. Click **Done** (or Cancel) on the warning.
2. Open **System Settings → Privacy & Security**, scroll down, and you'll see a note that "DockTube" was blocked. Click **Open Anyway**.
3. Open DockTube again and click **Open**. You only need to do this once.

If you're comfortable with Terminal, this one-liner does the same thing:

```bash
xattr -dr com.apple.quarantine /Applications/DockTube.app
```

## How to use

When the app starts, it asks for a YouTube link. If you already have a YouTube link on your clipboard, it's filled in for you.

| Action | Result |
| --- | --- |
| **Click** the Dock icon | Play / Pause (opens the link prompt if nothing is playing) |
| **Right-click** the Dock icon | Open the menu |

> The app's menus are currently in Korean. Each menu item below is listed as **Korean label** (English meaning).

### Right-click menu

- **재생 / 일시정지** (Play / Pause)
- **음소거** (Mute)
- **시간 이동…** (Jump to time…) — pick a position with a slider
- **⏪ 10초 뒤로 / ⏩ 10초 앞으로** (Back / Forward 10 seconds)
- **⏮ 이전 영상 / ⏭ 다음 영상** (Previous / Next video) — in a playlist, follows the playlist order; for a single video, *next* plays YouTube's recommended video and *previous* goes back to the one you just watched. In Shorts mode these become **이전 쇼츠 / 다음 쇼츠** (Previous / Next Short)
- **재생목록** (Playlist) — click any title to jump to it
- **화질** (Quality) — **자동** (Auto), **최고 화질 고정** (Always best), **1080p 고정** (Always 1080p), or any quality the video offers (e.g. 1080p60, 720p). If a video doesn't have the chosen quality, the best one below it is used. Remembered across restarts
- **자막** (Subtitles) — turn YouTube subtitles on/off (off by default). The player reloads and resumes where you were. Korean subtitles are preferred when available
- **유튜브 링크 열기…** (Open YouTube link…)
- **쇼츠 피드 보기** (Watch Shorts feed) — scroll through YouTube Shorts like in a browser (see *Shorts mode* below)
- **유튜브 로그인… / 유튜브 로그아웃** (Sign in to YouTube… / Sign out) — shows the Google sign-in page. Once signed in, Shorts are personalized for your account. Signing out clears all cookies and site data stored by the app
- **영상 파일 열기…** (Open video file…) — local files such as mp4 and mov
- **아이콘 꽉 채우기** (Fill icon) — on: fill the whole icon (edges cropped); off: show the entire video
- **미니 플레이어** (Mini player) — a small widescreen player just above the Dock (see below)
- **영상 창 보기** (Show video window) — reveals the hidden video window. Closing it with the red button hides it again

### Mini player

- Drag to move, drag the edges to resize (keeps 16:9). Position and size are remembered.
- Double-click to play/pause, right-click for the same menu as the Dock icon.
- Hover over it and the controls fade in:
  - **✕** (top right) — close the mini player (reopen it from the right-click menu)
  - Red **timeline** — grows when you hover; drag to seek
  - **⏮ ⏯ ⏭** — previous / play-pause / next
  - **🔊 Volume** — click the speaker to mute, drag the white bar to change volume (applies to YouTube, Shorts and video files; remembered across restarts)

### Supported YouTube links

- `https://www.youtube.com/watch?v=...`
- `https://youtu.be/...`
- `https://www.youtube.com/shorts/...` (opens in Shorts mode)
- `.../embed/...`, `.../live/...`
- A bare 11-character video ID
- Playlists: `https://www.youtube.com/playlist?list=...` — plays in order. With both (`watch?v=...&list=...`), it starts from that video

When a single video ends, YouTube's recommended next video plays automatically. Turn off **자동으로 다음 영상** (Autoplay next video) in the right-click menu to loop the current video instead (remembered across restarts). Playlists go back to the first video after the last one.

### Shorts mode (experimental)

Paste a `https://www.youtube.com/shorts/...` link or choose **쇼츠 피드 보기** (Watch Shorts feed), and DockTube opens the real YouTube Shorts page instead of the embedded player.

- Use **⏭ 다음 쇼츠 / ⏮ 이전 쇼츠** (Next / Previous Short) to swipe through recommendations like in a browser.
- **자동으로 다음 쇼츠** (Autoplay next Short, on by default) — moves to the next Short when one ends. Turn it off to loop a single Short. Remembered across restarts.
- Sign in once with **유튜브 로그인…** and you stay signed in across restarts, with recommendations based on your account.
- Play/pause, mute and seeking work; the quality, subtitle and playlist menus are hidden in this mode.

## Building from source (for developers)

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
bash build.sh        # build DockTube.app (universal: Apple Silicon + Intel)
bash build.sh dmg    # also create DockTube.dmg for distribution
open DockTube.app
```

### How it works

- YouTube plays in a hidden `WKWebView` via the IFrame API; DockTube takes 30 snapshots per second and draws them onto the Dock icon.
- Video files play through `AVPlayer`, and frames are pulled directly and drawn onto the icon.
- The video window sits in a corner of the screen, almost fully transparent (alpha 0.01). If it were fully hidden, macOS would stop rendering it and the icon would freeze.

### Files

| File | Description |
| --- | --- |
| `DockTube.swift` | The entire app (single file) |
| `build.sh` | Builds the `.app` bundle and the distributable `.dmg` |
| `AppIcon.icns` / `AppIcon.png` | App icon (shown in the Dock before playback) |

## Known limitations

- YouTube playback requires an internet connection.
- Videos whose owners disabled embedding won't play.
- Mixes (`list=RD...`) and private playlists may not play. Very long playlists may only show the first part.
- Quality switching uses the player's internal functions, not YouTube's official API, so it may stop working if YouTube changes things. The Dock icon is small, so quality mostly matters for the mini player, the video window and data usage.
- Subtitles are YouTube-only. Nothing appears for videos without subtitles.
- Autoplay-next reads the "up next" video from the YouTube watch page. If YouTube changes the page format it may not find one, and the video loops instead. These recommendations are generic, not tied to your account.
- Shorts mode works with the YouTube web page directly, so swiping may break if YouTube changes the page. Text overlaid on the video (like the title) may show up in the icon, and Google may block signing in from inside the app.
- The app's menus are Korean only for now.
