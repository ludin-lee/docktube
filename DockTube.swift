// DockTube — Dock 아이콘 안에서 유튜브/영상 파일을 재생하는 작은 맥 앱
// 빌드: bash build.sh  →  open DockTube.app

import Cocoa
import WebKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    enum Source { case none, youtube, shorts, file }   // shorts: 진짜 유튜브 쇼츠 페이지 (임시 기능)

    var source: Source = .none
    var window: NSWindow!
    var webView: WKWebView!

    var player: AVPlayer?
    var videoOutput: AVPlayerItemVideoOutput?
    var endObserver: NSObjectProtocol?
    let ciContext = CIContext()

    let tileView = NSImageView()
    var timer: Timer?
    var snapshotInFlight = false
    var tickCount = 0

    var position: Double = 0            // 재생 위치(초)
    var duration: Double = 0            // 전체 길이(초), 0이면 아직 모름
    var seekLabel: NSTextField?         // 시간 이동 창의 "1:23 / 4:56" 글자
    var shortsRect = CGRect.zero        // 쇼츠 페이지에서 영상이 있는 영역 (아이콘엔 이 부분만 찍어요)
    // 영상/쇼츠가 끝나면 다음 추천으로 (기본 켜짐, 앱을 다시 켜도 기억)
    var autoNext = UserDefaults.standard.object(forKey: "autoNext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNext, forKey: "autoNext") }
    }
    var autoNextCooldown = Date.distantPast  // 넘긴 직후 또 넘기지 않게
    var mini: NSPanel!                       // Dock 위에 뜨는 미니 플레이어
    let miniView = MiniView()
    let miniControls = NSView()              // 미니 플레이어 위 조작 UI 전체 (스르륵 나타나고 사라져요)
    let miniBar = SlimBar()                  // 타임바
    let miniVolume = SlimBar()
    let miniTimeLabel = NSTextField(labelWithString: "")
    var miniPlay: PressButton!
    var miniMute: PressButton!
    var isPlaying = false
    var backStack: [String] = []             // 영상 하나 모드에서 "이전 영상"으로 돌아갈 곳

    // 음량 0~1 (앱을 다시 켜도 기억)
    var volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(volume, forKey: "volume") }
    }
    var loggedIn = false                     // 유튜브 로그인 쿠키가 있는지
    var recentVideos: [String] = []          // 최근 본 영상 (추천이 A→B→A로 돌지 않게)

    // 쇼츠 페이지에서 화면에 가장 크게 보이는 <video>
    static let shortsVideoJS = """
    (function(){ var best = null, area = 0;
      [].slice.call(document.querySelectorAll('video')).forEach(function(v){
        var r = v.getBoundingClientRect();
        var a = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0)) * Math.max(0, r.width);
        if (a > area) { area = a; best = v; } });
      return best; })()
    """

    var isMuted = false
    var captionsOn = false      // 유튜브 자막
    var fillMode = false        // true: 아이콘을 꽉 채움(가장자리 잘림) / false: 영상 전체가 보이게
    var windowShown = false

    var playlist: [String] = []         // 재생목록 영상 ID들 (웹페이지가 알려줘요)
    var playlistIndex = 0
    var currentList: String?            // 지금 재생 중인 재생목록/영상 ID (자막 바꿀 때 다시 불러오려고)
    var currentVideoID: String?
    var titles: [String: String] = [:]  // 영상 ID → 제목

    var qualities: [(q: String, label: String)] = []  // 유튜브가 주는 화질 목록 (예: hd1080 / 1080p60)
    var currentQuality = ""
    // 사용자가 고른 화질 상한 (nil = 자동). 그 화질이 없으면 그 아래에서 가장 좋은 걸 골라요. 앱을 껐다 켜도 유지돼요
    var wantQuality: String? = UserDefaults.standard.string(forKey: "quality") {
        didSet { UserDefaults.standard.set(wantQuality, forKey: "quality") }
    }
    static let qualityOrder = ["highres", "hd2880", "hd2160", "hd1440", "hd1080", "hd720", "large", "medium", "small", "tiny"]
    var playerFrame: WKFrameInfo?       // 유튜브 플레이어 iframe

    let iconSize: CGFloat = 256
    let fps: Double = 30

    // MARK: - 시작

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupWindow()
        setupMini()

        tileView.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = tileView
        setTile(makeIdleIcon())

        startTimer()

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.promptYouTube() }

        // 자동 업데이트: 켜고 10초 뒤, 그 뒤로 하루에 한 번
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if self.autoUpdate { self.checkForUpdate(manual: false) } }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            if self?.autoUpdate == true { self?.checkForUpdate(manual: false) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Dock 아이콘 클릭 → 재생/일시정지
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if source == .none { promptYouTube() } else { togglePlay() }
        return false
    }

    // Dock 아이콘 우클릭 메뉴
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if source != .none {
            menu.addItem(item(T("play_pause"), #selector(togglePlay)))
            let mute = item(T("mute"), #selector(toggleMute))
            mute.state = isMuted ? .on : .off
            menu.addItem(mute)
            if duration > 0 {
                menu.addItem(item("\(T("jump")) (\(timeText(position)) / \(timeText(duration)))", #selector(promptSeek)))
                menu.addItem(item(T("back10"), #selector(seekBack)))
                menu.addItem(item(T("fwd10"), #selector(seekForward)))
            }
            if source == .shorts {
                menu.addItem(item(T("prev_short"), #selector(prevVideo)))
                menu.addItem(item(T("next_short"), #selector(nextVideo)))
                let auto = item(T("auto_short"), #selector(toggleAutoNext))
                auto.state = autoNext ? .on : .off
                menu.addItem(auto)
            }
            if source == .youtube && playlist.isEmpty && currentList == nil {
                if !backStack.isEmpty { menu.addItem(item(T("prev_video"), #selector(prevVideo))) }
                menu.addItem(item(T("next_video"), #selector(nextVideo)))
                let auto = item(T("auto_video"), #selector(toggleAutoNext))
                auto.state = autoNext ? .on : .off
                menu.addItem(auto)
            }
            if !playlist.isEmpty {
                menu.addItem(item(T("prev_video"), #selector(prevVideo)))
                menu.addItem(item(T("next_video"), #selector(nextVideo)))
                let plItem = NSMenuItem(title: "\(T("playlist")) (\(playlistIndex + 1)/\(playlist.count))", action: nil, keyEquivalent: "")
                let pl = NSMenu()
                for (i, id) in playlist.enumerated() {
                    let title = titles[id].flatMap { $0.isEmpty ? nil : $0 } ?? id
                    let mi = item("\(i + 1). \(title)", #selector(playAt(_:)))
                    mi.tag = i
                    mi.state = i == playlistIndex ? .on : .off
                    pl.addItem(mi)
                }
                plItem.submenu = pl
                menu.addItem(plItem)
            }
            if !qualities.isEmpty {
                let qItem = NSMenuItem(title: T("quality"), action: nil, keyEquivalent: "")
                let qm = NSMenu()
                for (q, label) in [("auto", T("q_auto")), ("highres", T("q_best")), ("hd1080", T("q_1080"))] {
                    let mi = item(label, #selector(setQuality(_:)))
                    mi.representedObject = q
                    mi.state = q == (wantQuality ?? "auto") ? .on : .off
                    qm.addItem(mi)
                }
                qm.addItem(.separator())
                for (q, label) in qualities where q != "auto" {
                    let mi = item(q == currentQuality ? "\(label) (\(T("current")))" : label, #selector(setQuality(_:)))
                    mi.representedObject = q
                    mi.state = q == wantQuality ? .on : .off
                    qm.addItem(mi)
                }
                qItem.submenu = qm
                menu.addItem(qItem)
            }
            if source == .youtube {
                let cc = item(T("subtitles"), #selector(toggleCaptions))
                cc.state = captionsOn ? .on : .off
                menu.addItem(cc)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item(T("open_link"), #selector(promptYouTube)))
        menu.addItem(item(T("search"), #selector(promptSearch)))
        menu.addItem(item(T("shorts_feed"), #selector(openShortsFeed)))
        menu.addItem(loggedIn ? item(T("logout"), #selector(logoutYouTube))
                              : item(T("login"), #selector(loginYouTube)))
        menu.addItem(item(T("open_file"), #selector(openFile)))
        menu.addItem(.separator())
        let fill = item(T("fill"), #selector(toggleFill))
        fill.state = fillMode ? .on : .off
        menu.addItem(fill)
        let miniItem = item(T("mini"), #selector(toggleMini))
        miniItem.state = mini.isVisible ? .on : .off
        menu.addItem(miniItem)
        let show = item(T("show_window"), #selector(toggleWindow))
        show.state = windowShown ? .on : .off
        menu.addItem(show)
        menu.addItem(.separator())
        // 어느 언어에서도 찾을 수 있게 제목은 항상 "Language"
        let langItem = NSMenuItem(title: "🌐 Language", action: nil, keyEquivalent: "")
        let lm = NSMenu()
        for (code, name) in [("", T("lang_auto"))] + Lang.allCases.map({ ($0.rawValue, $0.name) }) {
            let mi = item(name, #selector(setLanguage(_:)))
            mi.representedObject = code
            mi.state = code == (Lang.chosen?.rawValue ?? "") ? .on : .off
            lm.addItem(mi)
        }
        langItem.submenu = lm
        menu.addItem(langItem)
        menu.addItem(item("\(T("update_check")) (v\(appVersion))", #selector(checkForUpdateManually)))
        let au = item(T("auto_update"), #selector(toggleAutoUpdate))
        au.state = autoUpdate ? .on : .off
        menu.addItem(au)
        return menu
    }

    @objc func setLanguage(_ sender: NSMenuItem) {
        Lang.chosen = Lang(rawValue: sender.representedObject as? String ?? "")
        setupMainMenu()   // 위쪽 메뉴 막대도 새 언어로
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    // 붙여넣기(⌘V)가 되려면 편집 메뉴가 필요해요
    func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: T("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: T("edit"))
        editMenu.addItem(NSMenuItem(title: T("cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: T("copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: T("paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: T("select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: - 숨은 영상 창

    // MARK: - 미니 플레이어

    func setupMini() {
        mini = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 216),
                       styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        mini.level = .floating
        mini.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        mini.isOpaque = false
        mini.backgroundColor = .clear
        mini.hasShadow = true
        mini.isReleasedWhenClosed = false
        mini.contentAspectRatio = NSSize(width: 16, height: 9)
        mini.minSize = NSSize(width: 320, height: 180)

        miniView.imageScaling = .scaleProportionallyUpOrDown
        miniView.wantsLayer = true
        miniView.layer?.backgroundColor = NSColor.black.cgColor
        miniView.layer?.cornerRadius = 10
        miniView.layer?.masksToBounds = true
        miniView.onDoubleClick = { [weak self] in self?.togglePlay() }
        miniView.onMenu = { [weak self] in self?.applicationDockMenu(NSApp) }
        mini.contentView = miniView
        setupMiniControls()

        // 처음엔 화면 아래 가운데, Dock 바로 위. 옮기거나 크기를 바꾸면 기억해요
        if !mini.setFrameUsingName("MiniPlayer"), let vf = NSScreen.main?.visibleFrame {
            mini.setFrameOrigin(NSPoint(x: vf.midX - mini.frame.width / 2, y: vf.minY + 8))
        }
        mini.setFrameAutosaveName("MiniPlayer")
    }

    // 조작 UI: 위쪽 ✕ / 아래쪽 타임바 · ⏮ ⏯ ⏭ · 시간 · 음량. 마우스를 올리면 스르륵 나타나요
    func setupMiniControls() {
        let w = mini.frame.width, h = mini.frame.height
        miniControls.frame = NSRect(x: 0, y: 0, width: w, height: h)
        miniControls.autoresizingMask = [.width, .height]
        miniControls.wantsLayer = true
        miniControls.alphaValue = 0
        miniControls.isHidden = true

        // 영상이 덜 가려지게, 위아래만 살짝 어둡게
        func shade(_ height: CGFloat, top: Bool) {
            let g = CAGradientLayer()
            g.colors = [NSColor(white: 0, alpha: top ? 0.55 : 0.8).cgColor, NSColor(white: 0, alpha: 0).cgColor]
            g.startPoint = CGPoint(x: 0.5, y: top ? 1 : 0)
            g.endPoint = CGPoint(x: 0.5, y: top ? 0 : 1)
            g.frame = CGRect(x: 0, y: top ? h - height : 0, width: w, height: height)
            g.autoresizingMask = top ? [.layerWidthSizable, .layerMinYMargin] : [.layerWidthSizable]
            miniControls.layer?.addSublayer(g)
        }
        shade(90, top: false)
        shade(44, top: true)

        let close = PressButton(symbol: "xmark", size: 11, target: self, action: #selector(toggleMini))
        close.frame = NSRect(x: w - 34, y: h - 34, width: 26, height: 26)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        miniControls.addSubview(close)

        miniBar.frame = NSRect(x: 8, y: 38, width: w - 16, height: 16)
        miniBar.autoresizingMask = [.width]
        miniBar.color = NSColor(calibratedRed: 1, green: 0, blue: 0.2, alpha: 1)
        miniBar.onChange = { [weak self] v, done in
            guard let self = self, self.duration > 0 else { return }
            self.miniTimeLabel.stringValue = "\(self.timeText(v * self.duration)) / \(self.timeText(self.duration))"
            if done { self.seek(to: v * self.duration) }
        }
        miniControls.addSubview(miniBar)

        let prev = PressButton(symbol: "backward.fill", size: 13, target: self, action: #selector(prevVideo))
        miniPlay = PressButton(symbol: "play.fill", size: 17, target: self, action: #selector(togglePlay))
        let next = PressButton(symbol: "forward.fill", size: 13, target: self, action: #selector(nextVideo))
        prev.frame = NSRect(x: 8, y: 6, width: 30, height: 30)
        miniPlay.frame = NSRect(x: 40, y: 4, width: 34, height: 34)
        next.frame = NSRect(x: 76, y: 6, width: 30, height: 30)
        [prev, miniPlay!, next].forEach(miniControls.addSubview)

        miniTimeLabel.frame = NSRect(x: 112, y: 13, width: 110, height: 16)
        miniTimeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        miniTimeLabel.textColor = NSColor(white: 1, alpha: 0.9)
        miniControls.addSubview(miniTimeLabel)

        miniMute = PressButton(symbol: "speaker.wave.2.fill", size: 12, target: self, action: #selector(toggleMute))
        miniMute.frame = NSRect(x: w - 112, y: 6, width: 30, height: 30)
        miniMute.autoresizingMask = [.minXMargin]
        miniControls.addSubview(miniMute)

        miniVolume.frame = NSRect(x: w - 82, y: 13, width: 72, height: 16)
        miniVolume.autoresizingMask = [.minXMargin]
        miniVolume.color = .white
        miniVolume.value = volume
        miniVolume.onChange = { [weak self] v, _ in self?.setVolume(v) }
        miniControls.addSubview(miniVolume)

        miniView.addSubview(miniControls)
        miniView.onHover = { [weak self] inside in self?.fadeMiniControls(inside) }
    }

    func fadeMiniControls(_ show: Bool) {
        if show { miniControls.isHidden = false; updateMiniControls() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = show ? 0.22 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            miniControls.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self = self, !show, self.miniControls.alphaValue == 0 else { return }
            self.miniControls.isHidden = true   // 안 보일 땐 클릭도 안 받게
        })
    }

    func updateMiniControls() {
        guard mini.isVisible else { return }
        miniPlay.setSymbol(isPlaying ? "pause.fill" : "play.fill")
        miniMute.setSymbol(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        guard !miniBar.dragging else { return }   // 타임바를 끄는 동안엔 건드리지 않아요
        miniTimeLabel.stringValue = duration > 0 ? "\(timeText(position)) / \(timeText(duration))" : ""
        miniBar.value = duration > 0 ? position / duration : 0
    }

    func setVolume(_ v: Double) {
        volume = v
        switch source {
        case .youtube: webView.evaluateJavaScript("if (window.player && player.setVolume) player.setVolume(\(Int(volume * 100)))")
        case .file: player?.volume = Float(volume)
        case .shorts, .none: break  // 쇼츠는 updateTime이 매번 맞춰요
        }
    }

    @objc func toggleMini() { mini.isVisible ? mini.orderOut(nil) : mini.orderFrontRegardless() }

    func showFrame(_ src: NSImage) {
        setTile(compose(src))
        if mini.isVisible { miniView.image = src }
    }

    func setupWindow() {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 360)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "DockTube"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "dt")
        config.userContentController.add(self, name: "dtq")
        // 공식 API의 화질 설정은 2019년부터 동작하지 않아서, 유튜브 iframe 안의 플레이어를 직접 다뤄요
        config.userContentController.addUserScript(WKUserScript(source: """
        if (/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname) && location.pathname.indexOf('/embed/') === 0) {
          var dtLast = '';
          window.dtSetQuality = function(q){
            var p = document.getElementById('movie_player');
            if (p && p.setPlaybackQualityRange) p.setPlaybackQualityRange(q, q);
          };
          setInterval(function(){
            var p = document.getElementById('movie_player');
            if (!p || !p.getAvailableQualityLevels) return;
            var levels = p.getAvailableQualityData
              ? p.getAvailableQualityData().map(function(d){ return [d.quality, d.qualityLabel || d.quality]; })
              : p.getAvailableQualityLevels().map(function(q){ return [q, q]; });
            var msg = {levels: levels, current: p.getPlaybackQuality()};
            var s = JSON.stringify(msg);
            if (s !== dtLast) { dtLast = s; window.webkit.messageHandlers.dtq.postMessage(msg); }
          }, 1000);
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        webView = WKWebView(frame: rect, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        window.contentView = webView

        hideVideoWindow()
    }

    // 창은 거의 투명하게 화면 구석에 띄워 둬요. (완전히 숨기면 macOS가 화면 그리기를 멈춰서요)
    func hideVideoWindow() {
        windowShown = false
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        if let vf = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: vf.minX, y: vf.minY))
        }
        window.orderFrontRegardless()
    }

    func showVideoWindow() {
        windowShown = true
        window.alphaValue = 1
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleWindow() { windowShown ? hideVideoWindow() : showVideoWindow() }

    // 빨간 닫기 버튼 → 앱 종료 대신 다시 숨기기
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideVideoWindow()
        return false
    }

    // MARK: - 유튜브

    @objc func promptYouTube() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = T("prompt_title")
        alert.informativeText = T("prompt_info")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = T("prompt_placeholder")
        if let clip = NSPasteboard.general.string(forType: .string),
           videoID(from: clip) != nil || playlistID(from: clip) != nil {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: T("play"))
        alert.addButton(withTitle: T("open_file"))
        alert.addButton(withTitle: T("cancel"))
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let text = field.stringValue
            let id = videoID(from: text), list = playlistID(from: text)
            if text.contains("/shorts") && list == nil {
                playShorts(id)
            } else if id != nil || list != nil {
                playYouTube(id, list: list)
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                searchYouTube(text)   // 링크가 아니면 검색어로
            }
        case .alertSecondButtonReturn:
            openFile()
        default:
            break
        }
    }

    func videoID(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?:v=|youtu\.be/|shorts/|embed/|live/)([A-Za-z0-9_-]{11})"#,
            #"^(?=.*[0-9_-])([A-Za-z0-9_-]{11})$"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t) else { continue }
            return String(t[r])
        }
        return nil
    }

    // MARK: - 검색 (API 키 없이 유튜브 검색 결과 페이지를 읽어요)

    @objc func promptSearch() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = T("search_title")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = T("search_placeholder")
        alert.accessoryView = field
        alert.addButton(withTitle: T("search_button"))
        alert.addButton(withTitle: T("cancel"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            searchYouTube(field.stringValue)
        }
    }

    func searchYouTube(_ query: String) {
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [URLQueryItem(name: "search_query", value: query)]
        var req = URLRequest(url: c.url!)
        req.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Lang.current.rawValue, forHTTPHeaderField: "Accept-Language")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let results = parseSearch(String(decoding: data ?? Data(), as: UTF8.self))
            DispatchQueue.main.async { self?.showResults(results, for: query) }
        }.resume()
    }

    // 결과를 메뉴로: 썸네일 + 제목 + 채널 · 길이. 누르면 재생
    func showResults(_ results: [SearchResult], for query: String) {
        guard !results.isEmpty else { return showMessage(T("no_results")) }
        let menu = NSMenu()
        let header = NSMenuItem(title: "🔍 \(query)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for r in results {
            let mi = item(r.title, #selector(playSearchResult(_:)))
            mi.representedObject = r.id
            let title = r.title.count > 60 ? r.title.prefix(60) + "…" : r.title
            let t = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 13)])
            t.append(NSAttributedString(string: "\n" + r.meta, attributes: [.font: NSFont.menuFont(ofSize: 11),
                                                                           .foregroundColor: NSColor.secondaryLabelColor]))
            mi.attributedTitle = t
            menu.addItem(mi)
            URLSession.shared.dataTask(with: URL(string: "https://i.ytimg.com/vi/\(r.id)/mqdefault.jpg")!) { data, _, _ in
                guard let data = data, let img = NSImage(data: data) else { return }
                img.size = NSSize(width: 96, height: 54)
                DispatchQueue.main.async { mi.image = img }
            }.resume()
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func playSearchResult(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        playYouTube(id)
    }

    func playlistID(from text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"[?&]list=([A-Za-z0-9_-]+)"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // list가 있으면 재생목록을 차례대로 재생해요 (id도 있으면 그 영상부터)
    func playYouTube(_ id: String?, list: String? = nil, start: Int = 0) {
        currentList = list
        currentVideoID = id
        setVideoSize(vertical: false)
        stopFile()
        source = .youtube
        playlist = []
        qualities = []
        playerFrame = nil
        duration = 0
        position = 0
        playlistIndex = 0
        let videoVar = id.map { "videoId: '\($0)'," } ?? ""
        let listVars = list.map { "listType:'playlist', list:'\($0)'," } ?? ""
        let origin = "https://docktube.local"
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        #p{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head>
        <body><div id="p"></div>
        <script>
        var player, cc = \(captionsOn), isList = \(list != nil), autoNext = \(autoNext);
        // 켤 때는 cc_load_policy로 처음부터 켜서 불러와요. 끌 때는 유튜브가 자막을 다시 붙여도 매번 떼요
        function applyCC(){
          if (cc || !player || !player.getOptions) return;
          if (player.getOptions().indexOf('captions') >= 0) player.unloadModule('captions');
        }
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('p', {
            \(videoVar) width: '100%', height: '100%',
            playerVars: {\(listVars) autoplay:1, playsinline:1, controls:0, rel:0, fs:0,
                         iv_load_policy:3, disablekb:1, \(captionsOn ? "cc_load_policy:1, cc_lang_pref:'\(Lang.current.rawValue)'," : "") start:\(start), origin:'\(origin)'},
            events: {
              onReady: function(e){ if (\(isMuted ? "true" : "false")) e.target.mute(); e.target.setVolume(\(Int(volume * 100))); e.target.playVideo(); },
              onApiChange: applyCC,
              onStateChange: function(e){
                if (e.data === 1) applyCC();
                if (isList) {
                  var ids = player.getPlaylist() || [], i = player.getPlaylistIndex();
                  window.webkit.messageHandlers.dt.postMessage({ids: ids, index: i});
                  if (e.data === 0 && i >= ids.length - 1) player.playVideoAt(0);  // 마지막 영상 끝 → 처음부터
                } else if (e.data === 0) {
                  if (autoNext) window.webkit.messageHandlers.dt.postMessage({ended: true});  // 다음 영상은 앱이 찾아요
                  else { player.seekTo(0); player.playVideo(); }
                }
              }
            }
          });
        }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: origin)!)
    }

    // 웹페이지 → 앱: 재생목록과 현재 순서
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard source == .youtube, let d = message.body as? [String: Any] else { return }
        if message.name == "dtq" {
            playerFrame = message.frameInfo
            let levels = d["levels"] as? [[String]] ?? []
            qualities = levels.filter { $0.count == 2 }.map { (q: $0[0], label: $0[1]) }
            currentQuality = d["current"] as? String ?? ""
            // 다음 영상(재생목록)·다시 불러오기 후에도 고른 화질을 유지해요
            if let target = resolveQuality(), target != currentQuality { applyQuality(target) }
            return
        }
        if d["ended"] != nil { playNextRelated(); return }
        guard let ids = d["ids"] as? [String] else { return }
        playlist = ids
        playlistIndex = d["index"] as? Int ?? 0
        for id in ids where titles[id] == nil { fetchTitle(id) }
    }

    // 제목은 유튜브 oEmbed로 가져와요 (API 키 필요 없음)
    func fetchTitle(_ id: String) {
        titles[id] = ""
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [URLQueryItem(name: "format", value: "json"),
                        URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = json["title"] as? String else { return }
            DispatchQueue.main.async { self.titles[id] = t }
        }.resume()
    }

    // 영상 하나가 끝나면: 유튜브 영상 페이지에 있는 "자동재생 다음 영상"을 꺼내서 틀어요. 못 찾으면 처음부터 반복
    func playNextRelated() {
        guard let id = currentVideoID else { return replayYouTube() }
        recentVideos = Array((recentVideos + [id]).suffix(30))
        var req = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
        req.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                guard let self = self, self.source == .youtube, self.currentVideoID == id else { return }
                if let next = self.pickNext(from: html) {
                    self.backStack = Array((self.backStack + [id]).suffix(50))
                    self.playYouTube(next)
                } else { self.replayYouTube() }
            }
        }.resume()
    }

    // 자동재생 영상을 먼저, 없으면 관련 영상 중에서 최근에 안 본 것
    func pickNext(from html: String) -> String? {
        func ids(_ s: String) -> [String] {
            let re = try! NSRegularExpression(pattern: #""videoId":"([A-Za-z0-9_-]{11})""#)
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range(at: 1), in: s).map { String(s[$0]) }
            }
        }
        var candidates: [String] = []
        if let r = html.range(of: "\"autoplayVideo\"") { candidates += ids(String(html[r.lowerBound...].prefix(2000))) }
        candidates += ids(html)
        return candidates.first { !recentVideos.contains($0) }
    }

    func replayYouTube() { webView.evaluateJavaScript("player.seekTo(0); player.playVideo();") }

    @objc func setQuality(_ sender: NSMenuItem) {
        guard let q = sender.representedObject as? String else { return }
        wantQuality = q == "auto" ? nil : q
        applyQuality(resolveQuality() ?? "auto")
    }

    // 상한 이하에서 이 영상이 제공하는 가장 좋은 화질
    func resolveQuality() -> String? {
        guard let want = wantQuality, let start = Self.qualityOrder.firstIndex(of: want) else { return nil }
        return Self.qualityOrder[start...].first { q in qualities.contains { $0.q == q } }
    }

    func applyQuality(_ q: String) {
        guard let frame = playerFrame else { return }
        webView.evaluateJavaScript("dtSetQuality('\(q)')", in: frame, in: .page) { _ in }
    }

    var isSingleVideo: Bool { source == .youtube && currentList == nil }

    @objc func prevVideo() {
        if source == .shorts { swipeShorts(down: false) }
        else if isSingleVideo { if let id = backStack.popLast() { playYouTube(id) } }
        else if source == .youtube { webView.evaluateJavaScript("player.previousVideo()") }
    }

    @objc func nextVideo() {
        if source == .shorts { swipeShorts(down: true) }
        else if isSingleVideo { playNextRelated() }
        else if source == .youtube { webView.evaluateJavaScript("player.nextVideo()") }
    }

    // MARK: - 쇼츠 (임시): youtube.com/shorts 페이지를 그대로 열어요. 로그인하면 내 추천이 나와요

    func playShorts(_ id: String?) {
        stopFile()
        source = .shorts
        playlist = []
        qualities = []
        playerFrame = nil
        duration = 0
        position = 0
        shortsRect = .zero
        setVideoSize(vertical: true)
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com/shorts/" + (id ?? ""))!))
    }

    @objc func openShortsFeed() { playShorts(nil) }
    @objc func toggleAutoNext() {
        autoNext.toggle()
        if source == .youtube { webView.evaluateJavaScript("autoNext = \(autoNext)") }
    }

    @objc func loginYouTube() {
        playShorts(nil)
        var c = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        c.queryItems = [URLQueryItem(name: "service", value: "youtube"),
                        URLQueryItem(name: "continue", value: "https://www.youtube.com/shorts")]
        webView.load(URLRequest(url: c.url!))
        showVideoWindow()
    }

    // 로그인하면 youtube.com에 LOGIN_INFO / SAPISID 쿠키가 생겨요
    func refreshLogin() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            self?.loggedIn = cookies.contains { $0.domain.hasSuffix("youtube.com") && ["LOGIN_INFO", "SAPISID"].contains($0.name) }
        }
    }

    // 쿠키·사이트 데이터를 모두 지워서 로그아웃
    @objc func logoutYouTube() {
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self = self else { return }
            self.loggedIn = false
            if self.source == .shorts { self.webView.reload() }
        }
    }

    // 쇼츠 페이지의 "다음/이전" 버튼을 누르고, 없으면 ↓/↑ 키를 보내요
    func swipeShorts(down: Bool) {
        let dir = down ? "down" : "up"
        webView.evaluateJavaScript("""
        (function(){
          var b = document.querySelector('#navigation-button-\(dir) button');
          if (b) { b.click(); return; }
          var k = '\(down ? "ArrowDown" : "ArrowUp")';
          document.dispatchEvent(new KeyboardEvent('keydown', {key: k, code: k, keyCode: \(down ? 40 : 38), bubbles: true}));
        })()
        """)
    }

    func setVideoSize(vertical: Bool) {
        window.setContentSize(vertical ? NSSize(width: 405, height: 720) : NSSize(width: 640, height: 360))
        if !windowShown { hideVideoWindow() }
    }
    @objc func playAt(_ sender: NSMenuItem) { webView.evaluateJavaScript("player.playVideoAt(\(sender.tag))") }

    func stopYouTube() {
        webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
    }

    func snapshotWeb() {
        guard !snapshotInFlight else { return }
        snapshotInFlight = true
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = NSNumber(value: mini.isVisible ? 720 : 320)  // 미니 플레이어가 켜져 있으면 더 선명하게
        cfg.afterScreenUpdates = false
        if source == .shorts {
            guard shortsRect.width > 10, shortsRect.height > 10 else { snapshotInFlight = false; return }
            cfg.rect = shortsRect
        }
        webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self = self else { return }
            self.snapshotInFlight = false
            if self.source == .youtube || self.source == .shorts, let image = image {
                self.showFrame(image)
            }
        }
    }

    // MARK: - 영상 파일

    @objc func openFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            playFile(url)
        }
    }

    func playFile(_ url: URL) {
        stopYouTube()
        stopFile()
        playlist = []
        qualities = []
        playerFrame = nil
        duration = 0
        position = 0
        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(out)
        let p = AVPlayer(playerItem: item)
        p.isMuted = isMuted
        p.volume = Float(volume)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        player = p
        videoOutput = out
        source = .file
        p.play()
    }

    func stopFile() {
        player?.pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        player = nil
        videoOutput = nil
    }

    func grabFileFrame() {
        guard let out = videoOutput else { return }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t),
              let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        showFrame(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }

    // MARK: - 조작

    @objc func togglePlay() {
        isPlaying.toggle()      // 버튼 모양은 바로 바꾸고, 실제 상태는 updateTime이 곧 맞춰요
        updateMiniControls()
        switch source {
        case .youtube:
            webView.evaluateJavaScript("""
            (function(){ if(!window.player||!player.getPlayerState) return -1;
              var s = player.getPlayerState();
              if (s === 1 || s === 3) { player.pauseVideo(); return 0; }
              player.playVideo(); return 1; })()
            """)
        case .shorts:
            webView.evaluateJavaScript("(function(v){ if (v) v.paused ? v.play() : v.pause(); })(\(Self.shortsVideoJS))")
        case .file:
            guard let p = player else { return }
            p.rate == 0 ? p.play() : p.pause()
        case .none:
            break
        }
    }

    @objc func toggleMute() {
        isMuted.toggle()
        updateMiniControls()
        switch source {
        case .youtube:
            webView.evaluateJavaScript("if(window.player&&player.mute){ \(isMuted ? "player.mute()" : "player.unMute()") }")
        case .shorts:
            break  // updateTime이 매번 맞춰요
        case .file:
            player?.isMuted = isMuted
        case .none:
            break
        }
    }

    @objc func toggleCaptions() {
        captionsOn.toggle()
        // 자막은 플레이어를 새로 불러와야 확실히 바뀌어요 → 보던 영상의 보던 시간부터 다시 재생
        webView.evaluateJavaScript("[player.getVideoData().video_id, player.getCurrentTime()]") { [weak self] r, _ in
            guard let self = self, self.source == .youtube else { return }
            let a = r as? [Any]
            let id = (a?.first as? String).flatMap { $0.isEmpty ? nil : $0 } ?? self.currentVideoID  // 플레이어가 아직 준비 전이면 처음 넣은 링크로
            let t = (a?.last as? NSNumber)?.intValue ?? 0
            self.playYouTube(id, list: self.currentList, start: t)
        }
    }

    @objc func toggleFill() { fillMode.toggle() }

    // MARK: - 재생 시간 / 이동

    func updateTime() {
        switch source {
        case .file:
            guard let p = player, let d = p.currentItem?.duration.seconds, d.isFinite else { return }
            position = p.currentTime().seconds
            duration = d
            isPlaying = p.rate != 0
        case .youtube:
            webView.evaluateJavaScript("window.player && player.getDuration ? [player.getCurrentTime(), player.getDuration(), player.getPlayerState()] : null") { [weak self] r, _ in
                guard let self = self, self.source == .youtube,
                      let a = r as? [NSNumber], a.count == 3 else { return }
                self.position = a[0].doubleValue
                self.duration = a[1].doubleValue
                self.isPlaying = a[2].intValue == 1 || a[2].intValue == 3
            }
        case .shorts:
            // 시간·길이·영상 영역을 읽고, 음소거 설정도 맞춰요 (다음 쇼츠로 넘어가면 영상이 바뀌니까 매번)
            webView.evaluateJavaScript("""
            (function(v){ if (!v) return null; v.muted = \(isMuted); v.volume = \(volume);
              var r = v.getBoundingClientRect();
              return [v.currentTime, v.duration || 0, r.left, r.top, r.width, r.height, v.paused ? 0 : 1]; })(\(Self.shortsVideoJS))
            """) { [weak self] r, _ in
                guard let self = self, self.source == .shorts,
                      let a = (r as? [NSNumber])?.map({ $0.doubleValue }), a.count == 7 else { return }
                self.isPlaying = a[6] == 1
                let prev = self.position
                self.position = a[0]
                self.duration = a[1].isFinite ? a[1] : 0
                // 쇼츠는 끝나면 스스로 처음부터 반복해요 → 끝에 닿았거나, 끝 근처에서 0으로 되감기면 다음으로
                let d = self.duration
                if self.autoNext, d > 1, Date() > self.autoNextCooldown,
                   a[0] >= d - 0.35 || (a[0] + 1 < prev && prev > d - 1.5) {
                    self.autoNextCooldown = Date().addingTimeInterval(2)
                    self.swipeShorts(down: true)
                }
                self.shortsRect = CGRect(x: a[2], y: a[3], width: a[4], height: a[5])
                    .intersection(self.webView.bounds)
            }
        case .none:
            break
        }
    }

    func seek(to t: Double) {
        let t = min(max(t, 0), max(duration - 1, 0))
        position = t
        switch source {
        case .youtube: webView.evaluateJavaScript("player.seekTo(\(t), true)")
        case .shorts: webView.evaluateJavaScript("(function(v){ if (v) v.currentTime = \(t); })(\(Self.shortsVideoJS))")
        case .file: player?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        case .none: break
        }
    }

    @objc func seekBack() { seek(to: position - 10) }
    @objc func seekForward() { seek(to: position + 10) }

    @objc func promptSeek() {
        guard duration > 0 else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = T("seek_title")
        alert.informativeText = T("seek_info")

        let v = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 46))
        let slider = NSSlider(value: position, minValue: 0, maxValue: duration,
                              target: self, action: #selector(seekSliderMoved(_:)))
        slider.frame = NSRect(x: 0, y: 22, width: 340, height: 24)
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 0, y: 0, width: 340, height: 18)
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        v.addSubview(slider)
        v.addSubview(label)
        seekLabel = label
        seekSliderMoved(slider)

        alert.accessoryView = v
        alert.addButton(withTitle: T("go"))
        alert.addButton(withTitle: T("cancel"))
        if alert.runModal() == .alertFirstButtonReturn { seek(to: slider.doubleValue) }
        seekLabel = nil
    }

    @objc func seekSliderMoved(_ s: NSSlider) {
        seekLabel?.stringValue = "\(timeText(s.doubleValue)) / \(timeText(duration))"
    }

    func timeText(_ t: Double) -> String {
        let s = Int(t.isFinite ? t : 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    func startTimer() {
        let t = Timer(timeInterval: 1.0 / fps, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Dock 아이콘 그리기

    @objc func tick() {
        tickCount += 1
        if tickCount % 10 == 0 { updateTime(); updateMiniControls() }  // 재생 시간은 초당 3번이면 충분해요
        // 쿠키 변경 알림은 로그인 때 안 올 때가 있어서, 3초마다 직접 확인해요
        if tickCount % 90 == 1 { refreshLogin() }
        switch source {
        case .youtube, .shorts: snapshotWeb()
        case .file: grabFileFrame()
        case .none: break
        }
    }

    func setTile(_ image: NSImage) {
        tileView.image = image
        NSApp.dockTile.display()
    }

    func iconFrame() -> (NSRect, NSBezierPath) {
        let inset = iconSize * 0.06
        let box = NSRect(x: inset, y: inset, width: iconSize - inset * 2, height: iconSize - inset * 2)
        let path = NSBezierPath(roundedRect: box, xRadius: box.width * 0.22, yRadius: box.width * 0.22)
        return (box, path)
    }

    func compose(_ src: NSImage) -> NSImage {
        let img = NSImage(size: NSSize(width: iconSize, height: iconSize))
        img.lockFocus()
        let (box, path) = iconFrame()
        NSColor.black.setFill()
        path.fill()
        path.addClip()
        let iw = max(src.size.width, 1), ih = max(src.size.height, 1)
        let scale = fillMode ? max(box.width / iw, box.height / ih) : min(box.width / iw, box.height / ih)
        let w = iw * scale, h = ih * scale
        src.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        return img
    }

    func makeIdleIcon() -> NSImage {
        // 앱 아이콘(AppIcon.icns)이 있으면 그걸 그대로 보여줘요
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        let img = NSImage(size: NSSize(width: iconSize, height: iconSize))
        img.lockFocus()
        let (box, path) = iconFrame()
        NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill()
        path.fill()
        let tri = NSBezierPath()
        let c = NSPoint(x: box.midX + box.width * 0.04, y: box.midY)
        let r = box.width * 0.22
        tri.move(to: NSPoint(x: c.x - r * 0.8, y: c.y + r))
        tri.line(to: NSPoint(x: c.x + r, y: c.y))
        tri.line(to: NSPoint(x: c.x - r * 0.8, y: c.y - r))
        tri.close()
        NSColor.white.setFill()
        tri.fill()
        img.unlockFocus()
        return img
    }

    // MARK: - 업데이트 (GitHub 릴리스에서 새 DockTube.dmg를 받아 바꿔 끼우고 다시 켜요)

    static let repo = "ludin-lee/docktube"
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }
    var skippedVersion: String? {   // 자동 확인에서 "나중에" 누른 버전은 다시 안 물어봐요 (수동 확인은 물어봐요)
        get { UserDefaults.standard.string(forKey: "skippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedVersion") }
    }

    @objc func toggleAutoUpdate() { autoUpdate.toggle() }
    @objc func checkForUpdateManually() { checkForUpdate(manual: true) }

    func checkForUpdate(manual: Bool) {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let json = json, let tag = json["tag_name"] as? String else {
                    if manual { self.showMessage(T("update_failed")) }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let dmg = (json["assets"] as? [[String: Any]])?
                    .compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".dmg") }
                guard isNewer(latest, than: self.appVersion), let dmgURL = dmg.flatMap(URL.init(string:)) else {
                    if manual { self.showMessage(T("up_to_date").replacingOccurrences(of: "{v}", with: self.appVersion)) }
                    return
                }
                if !manual && self.skippedVersion == latest { return }
                self.askToInstall(latest, notes: json["body"] as? String ?? "", dmg: dmgURL,
                                  page: (json["html_url"] as? String).flatMap(URL.init(string:)))
            }
        }.resume()
    }

    func askToInstall(_ version: String, notes: String, dmg: URL, page: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = T("update_available").replacingOccurrences(of: "{v}", with: version)
        alert.informativeText = T("update_info") + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        alert.addButton(withTitle: T("update_now"))
        alert.addButton(withTitle: T("later"))
        guard alert.runModal() == .alertFirstButtonReturn else { skippedVersion = version; return }
        installUpdate(from: dmg, page: page)
    }

    // 1) DMG 받기 → 2) 열어서 새 앱을 임시 폴더로 복사 → 3) 앱이 꺼지면 바꿔 끼우고 다시 켜는 스크립트 실행 → 4) 종료
    func installUpdate(from dmg: URL, page: URL?) {
        let dest = Bundle.main.bundlePath
        let fail = { [weak self] in
            self?.showMessage(T("update_failed"))
            if let page = page { NSWorkspace.shared.open(page) }
        }
        // 응용 프로그램 폴더에 쓸 권한이 없으면 직접 받게 안내
        guard FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent),
              FileManager.default.isWritableFile(atPath: dest) else { return fail() }

        URLSession.shared.downloadTask(with: dmg) { file, _, _ in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DockTubeUpdate-\(UUID().uuidString)")
            let dmgPath = tmp.appendingPathComponent("DockTube.dmg").path
            let mount = tmp.appendingPathComponent("mnt").path
            let newApp = tmp.appendingPathComponent("DockTube.app").path
            func run(_ args: [String]) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                do { try p.run() } catch { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }
            guard let file = file,
                  (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
                  (try? FileManager.default.moveItem(atPath: file.path, toPath: dmgPath)) != nil,
                  run(["hdiutil", "attach", dmgPath, "-nobrowse", "-readonly", "-mountpoint", mount]) else {
                return DispatchQueue.main.async(execute: fail)
            }
            let copied = run(["ditto", mount + "/DockTube.app", newApp])
            _ = run(["hdiutil", "detach", mount, "-quiet"])
            guard copied else { return DispatchQueue.main.async(execute: fail) }

            // 이 앱이 완전히 꺼질 때까지 기다렸다가 바꿔 끼우고 다시 켜요
            let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2" && ditto "$3" "$2" && xattr -dr com.apple.quarantine "$2" 2>/dev/null
            open "$2"
            rm -rf "$4"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)", dest, newApp, tmp.path]
            do { try p.run() } catch { return DispatchQueue.main.async(execute: fail) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }

    func showMessage(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }
}

// 미니 플레이어 화면: 드래그로 옮기기, 더블클릭 재생/일시정지, 우클릭 메뉴
final class MiniView: NSImageView {
    var onDoubleClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { window?.performDrag(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
}

// MARK: - 검색 결과 읽기

struct SearchResult { let id: String, title: String, meta: String }

// 유튜브 검색 페이지 안의 ytInitialData(JSON)에서 영상(videoRenderer)만 순서대로 꺼내요
func parseSearch(_ html: String) -> [SearchResult] {
    guard let s = html.range(of: "var ytInitialData = "),
          let e = html.range(of: ";</script>", range: s.upperBound..<html.endIndex),
          let data = html[s.upperBound..<e.lowerBound].data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
    func text(_ x: Any?) -> String? {
        let d = x as? [String: Any]
        return d?["simpleText"] as? String ?? (d?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
    }
    var out: [SearchResult] = []
    func walk(_ x: Any) {
        if let d = x as? [String: Any] {
            if let v = d["videoRenderer"] as? [String: Any], let id = v["videoId"] as? String {
                let meta = [text(v["ownerText"]), text(v["lengthText"])].compactMap { $0 }.joined(separator: " · ")
                out.append(SearchResult(id: id, title: text(v["title"]) ?? id, meta: meta))
                return
            }
            d.values.forEach(walk)
        } else if let a = x as? [Any] {
            a.forEach(walk)
        }
    }
    walk(json)
    var seen = Set<String>()
    return out.filter { seen.insert($0.id).inserted }
}

// "1.10" > "1.9"처럼 숫자로 비교해요
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

// MARK: - 언어

enum Lang: String, CaseIterable {
    case ko, en, ja, zh, es

    var name: String { ["한국어", "English", "日本語", "中文", "Español"][Self.allCases.firstIndex(of: self)!] }

    // 사용자가 고른 언어 (nil = 맥 언어 설정 따르기)
    static var chosen: Lang? {
        get { UserDefaults.standard.string(forKey: "lang").flatMap(Lang.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "lang") }
    }

    static var current: Lang {
        chosen ?? Lang(rawValue: String((Locale.preferredLanguages.first ?? "en").prefix(2))) ?? .en
    }
}

// 번역표: 한국어, English, 日本語, 中文, Español 순서
let strings: [String: [String]] = [
    "play_pause": ["재생 / 일시정지", "Play / Pause", "再生 / 一時停止", "播放 / 暂停", "Reproducir / Pausa"],
    "mute": ["음소거", "Mute", "ミュート", "静音", "Silenciar"],
    "jump": ["시간 이동…", "Jump to Time…", "時間を移動…", "跳转到时间…", "Ir a un momento…"],
    "back10": ["⏪ 10초 뒤로", "⏪ Back 10 Seconds", "⏪ 10秒戻る", "⏪ 后退 10 秒", "⏪ Retroceder 10 s"],
    "fwd10": ["⏩ 10초 앞으로", "⏩ Forward 10 Seconds", "⏩ 10秒進む", "⏩ 前进 10 秒", "⏩ Avanzar 10 s"],
    "prev_short": ["⏮ 이전 쇼츠", "⏮ Previous Short", "⏮ 前のショート", "⏮ 上一个短视频", "⏮ Short anterior"],
    "next_short": ["⏭ 다음 쇼츠", "⏭ Next Short", "⏭ 次のショート", "⏭ 下一个短视频", "⏭ Siguiente Short"],
    "auto_short": ["자동으로 다음 쇼츠", "Autoplay Next Short", "次のショートを自動再生", "自动播放下一个短视频", "Reproducir el siguiente Short automáticamente"],
    "prev_video": ["⏮ 이전 영상", "⏮ Previous Video", "⏮ 前の動画", "⏮ 上一个视频", "⏮ Video anterior"],
    "next_video": ["⏭ 다음 영상", "⏭ Next Video", "⏭ 次の動画", "⏭ 下一个视频", "⏭ Siguiente video"],
    "auto_video": ["자동으로 다음 영상", "Autoplay Next Video", "次の動画を自動再生", "自动播放下一个视频", "Reproducir el siguiente video automáticamente"],
    "playlist": ["재생목록", "Playlist", "再生リスト", "播放列表", "Lista de reproducción"],
    "quality": ["화질", "Quality", "画質", "画质", "Calidad"],
    "q_auto": ["자동", "Auto", "自動", "自动", "Automática"],
    "q_best": ["최고 화질 고정", "Always Best", "常に最高画質", "始终最高画质", "Siempre la mejor"],
    "q_1080": ["1080p 고정", "Always 1080p", "常に1080p", "始终 1080p", "Siempre 1080p"],
    "current": ["현재", "current", "現在", "当前", "actual"],
    "subtitles": ["자막", "Subtitles", "字幕", "字幕", "Subtítulos"],
    "open_link": ["유튜브 링크 열기…", "Open YouTube Link…", "YouTubeのリンクを開く…", "打开 YouTube 链接…", "Abrir enlace de YouTube…"],
    "shorts_feed": ["쇼츠 피드 보기", "Watch Shorts Feed", "ショートフィードを見る", "观看 Shorts 短视频", "Ver feed de Shorts"],
    "login": ["유튜브 로그인…", "Sign In to YouTube…", "YouTubeにログイン…", "登录 YouTube…", "Iniciar sesión en YouTube…"],
    "logout": ["유튜브 로그아웃", "Sign Out of YouTube", "YouTubeからログアウト", "退出 YouTube 登录", "Cerrar sesión de YouTube"],
    "open_file": ["영상 파일 열기…", "Open Video File…", "動画ファイルを開く…", "打开视频文件…", "Abrir archivo de video…"],
    "fill": ["아이콘 꽉 채우기", "Fill Icon", "アイコンいっぱいに表示", "填满图标", "Llenar el icono"],
    "mini": ["미니 플레이어", "Mini Player", "ミニプレーヤー", "迷你播放器", "Minirreproductor"],
    "show_window": ["영상 창 보기", "Show Video Window", "動画ウインドウを表示", "显示视频窗口", "Mostrar ventana de video"],
    "lang_auto": ["자동 (시스템 언어)", "Auto (System Language)", "自動（システム言語）", "自动（系统语言）", "Automático (idioma del sistema)"],
    "quit": ["DockTube 종료", "Quit DockTube", "DockTubeを終了", "退出 DockTube", "Salir de DockTube"],
    "edit": ["편집", "Edit", "編集", "编辑", "Editar"],
    "cut": ["잘라내기", "Cut", "カット", "剪切", "Cortar"],
    "copy": ["복사", "Copy", "コピー", "拷贝", "Copiar"],
    "paste": ["붙여넣기", "Paste", "ペースト", "粘贴", "Pegar"],
    "select_all": ["전체 선택", "Select All", "すべてを選択", "全选", "Seleccionar todo"],
    "prompt_title": ["유튜브 링크나 검색어를 넣으세요", "Paste a YouTube link or type a search", "YouTubeのリンクか検索ワードを入力してください", "粘贴 YouTube 链接或输入搜索词", "Pega un enlace de YouTube o escribe una búsqueda"],
    "prompt_info": ["Dock 아이콘에서 영상이 재생돼요. 아이콘을 클릭하면 재생/일시정지, 우클릭하면 메뉴가 나와요.",
                    "The video plays inside the Dock icon. Click the icon to play/pause, right-click for the menu.",
                    "動画はDockアイコンの中で再生されます。クリックで再生/一時停止、右クリックでメニューが開きます。",
                    "视频会在程序坞图标中播放。点按图标可播放/暂停，右键点按可打开菜单。",
                    "El video se reproduce dentro del icono del Dock. Haz clic para reproducir/pausar y clic derecho para ver el menú."],
    "prompt_placeholder": ["영상·재생목록 링크 또는 검색어", "Video/playlist link or search words", "動画・再生リストのリンクまたは検索ワード", "视频/播放列表链接或搜索词", "Enlace de video/lista o palabras de búsqueda"],
    "play": ["재생", "Play", "再生", "播放", "Reproducir"],
    "cancel": ["취소", "Cancel", "キャンセル", "取消", "Cancelar"],
    "seek_title": ["시간 이동", "Jump to Time", "時間を移動", "跳转到时间", "Ir a un momento"],
    "seek_info": ["슬라이더를 옮긴 뒤 이동을 누르세요.", "Move the slider, then click Go.", "スライダーを動かして「移動」を押してください。",
                  "拖动滑块，然后点按“跳转”。", "Mueve el control deslizante y pulsa Ir."],
    "search": ["🔍 유튜브 검색…", "🔍 Search YouTube…", "🔍 YouTubeを検索…", "🔍 搜索 YouTube…", "🔍 Buscar en YouTube…"],
    "search_title": ["유튜브 검색", "Search YouTube", "YouTubeを検索", "搜索 YouTube", "Buscar en YouTube"],
    "search_placeholder": ["검색어", "Search words", "検索ワード", "搜索词", "Palabras de búsqueda"],
    "search_button": ["검색", "Search", "検索", "搜索", "Buscar"],
    "no_results": ["검색 결과가 없어요.", "No results found.", "検索結果がありません。", "没有找到结果。", "No se encontraron resultados."],
    "update_check": ["업데이트 확인…", "Check for Updates…", "アップデートを確認…", "检查更新…", "Buscar actualizaciones…"],
    "auto_update": ["자동 업데이트", "Automatic Updates", "自動アップデート", "自动更新", "Actualizaciones automáticas"],
    "update_available": ["새 버전 {v}이(가) 나왔어요", "DockTube {v} is available", "新しいバージョン {v} があります", "DockTube {v} 已推出", "DockTube {v} está disponible"],
    "update_info": ["업데이트하면 앱이 잠깐 꺼졌다가 새 버전으로 다시 켜져요.", "DockTube will quit briefly and reopen with the new version.",
                    "アップデートするとアプリが一度終了し、新しいバージョンで再起動します。", "更新时 DockTube 会短暂退出，并以新版本重新打开。",
                    "DockTube se cerrará un momento y se volverá a abrir con la nueva versión."],
    "update_now": ["업데이트", "Update", "アップデート", "更新", "Actualizar"],
    "later": ["나중에", "Later", "後で", "以后", "Más tarde"],
    "up_to_date": ["최신 버전이에요 (v{v})", "You're up to date (v{v})", "最新バージョンです（v{v}）", "已是最新版本（v{v}）", "Tienes la última versión (v{v})"],
    "update_failed": ["업데이트하지 못했어요. 릴리스 페이지에서 직접 받아 주세요.", "Couldn't update automatically. Please download it from the release page.",
                      "アップデートできませんでした。リリースページから直接ダウンロードしてください。", "无法自动更新，请从发布页面手动下载。",
                      "No se pudo actualizar. Descárgala desde la página de versiones."],
    "go": ["이동", "Go", "移動", "跳转", "Ir"],
]

func T(_ key: String) -> String {
    guard let row = strings[key] else { return key }
    return row[Lang.allCases.firstIndex(of: Lang.current)!]
}

// 누르면 쏙 들어갔다 튕겨 나오고, 마우스를 올리면 동그란 배경이 스르륵 생기는 버튼
final class PressButton: NSButton {
    private var symbolName = ""
    private var pointSize: CGFloat = 13

    convenience init(symbol: String, size: CGFloat, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        pointSize = size
        setSymbol(symbol)
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .white
        wantsLayer = true
    }

    func setSymbol(_ name: String) {
        guard name != symbolName else { return }
        symbolName = name
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { fadeBackground(to: 0.2) }
    override func mouseExited(with event: NSEvent) { fadeBackground(to: 0) }

    override func mouseDown(with event: NSEvent) {
        scale(to: 0.8, spring: false)
        super.mouseDown(with: event)   // 손을 뗄 때까지 여기서 기다려요
        scale(to: 1, spring: true)
    }

    private func fadeBackground(to alpha: CGFloat) {
        guard let l = layer else { return }
        let to = NSColor(white: 1, alpha: alpha).cgColor
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = l.presentation()?.backgroundColor ?? l.backgroundColor
        a.toValue = to
        a.duration = 0.18
        l.backgroundColor = to
        l.add(a, forKey: "bg")
    }

    // 가운데를 기준으로 크기 바꾸기 (뷰 레이어는 기준점이 왼쪽 아래라서 옮겼다 되돌려요)
    private func scale(to s: CGFloat, spring: Bool) {
        guard let l = layer else { return }
        var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
        let a: CABasicAnimation
        if spring {
            let sp = CASpringAnimation(keyPath: "transform")
            sp.damping = 11
            sp.stiffness = 320
            sp.duration = sp.settlingDuration
            a = sp
        } else {
            a = CABasicAnimation(keyPath: "transform")
            a.duration = 0.08
        }
        a.fromValue = NSValue(caTransform3D: l.presentation()?.transform ?? l.transform)
        a.toValue = NSValue(caTransform3D: t)
        l.transform = t
        l.add(a, forKey: "press")
    }
}

// 얇은 바 슬라이더 (유튜브 타임바 느낌): 마우스를 올리면 두꺼워지고 동그란 손잡이가 스르륵 나와요
final class SlimBar: NSView {
    var color: NSColor = .white
    var value: Double = 0 { didSet { needsDisplay = true } }
    var onChange: ((Double, Bool) -> Void)?   // (값 0~1, 손을 뗐는지)
    private(set) var dragging = false
    @objc dynamic var hover: CGFloat = 0 { didSet { needsDisplay = true } }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "hover" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let th = 3 + 2 * hover
        let track = NSRect(x: 6, y: bounds.midY - th / 2, width: bounds.width - 12, height: th)
        NSColor(white: 1, alpha: 0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: th / 2, yRadius: th / 2).fill()
        var done = track
        done.size.width = track.width * CGFloat(min(max(value, 0), 1))
        color.setFill()
        NSBezierPath(roundedRect: done, xRadius: th / 2, yRadius: th / 2).fill()
        if hover > 0.01 {
            let r = 6 * hover
            NSBezierPath(ovalIn: NSRect(x: done.maxX - r, y: bounds.midY - r, width: r * 2, height: r * 2)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { animateHover(1) }
    override func mouseExited(with event: NSEvent) { if !dragging { animateHover(0) } }

    private func animateHover(_ v: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().hover = v
        }
    }

    override func mouseDown(with event: NSEvent) { dragging = true; track(event, done: false) }
    override func mouseDragged(with event: NSEvent) { track(event, done: false) }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        track(event, done: true)
        let p = convert(event.locationInWindow, from: nil)
        if !bounds.contains(p) { animateHover(0) }
    }

    private func track(_ event: NSEvent, done: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        value = Double(min(max((x - 6) / (bounds.width - 12), 0), 1))
        onChange?(value, done)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
