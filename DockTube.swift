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

        tileView.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = tileView
        setTile(makeIdleIcon())

        startTimer()

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.promptYouTube() }
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
            menu.addItem(item("재생 / 일시정지", #selector(togglePlay)))
            let mute = item("음소거", #selector(toggleMute))
            mute.state = isMuted ? .on : .off
            menu.addItem(mute)
            if duration > 0 {
                menu.addItem(item("시간 이동… (\(timeText(position)) / \(timeText(duration)))", #selector(promptSeek)))
                menu.addItem(item("⏪ 10초 뒤로", #selector(seekBack)))
                menu.addItem(item("⏩ 10초 앞으로", #selector(seekForward)))
            }
            if source == .shorts {
                menu.addItem(item("⏮ 이전 쇼츠", #selector(prevVideo)))
                menu.addItem(item("⏭ 다음 쇼츠", #selector(nextVideo)))
                let auto = item("자동으로 다음 쇼츠", #selector(toggleAutoNext))
                auto.state = autoNext ? .on : .off
                menu.addItem(auto)
            }
            if source == .youtube && playlist.isEmpty && currentList == nil {
                let auto = item("자동으로 다음 영상", #selector(toggleAutoNext))
                auto.state = autoNext ? .on : .off
                menu.addItem(auto)
            }
            if !playlist.isEmpty {
                menu.addItem(item("⏮ 이전 영상", #selector(prevVideo)))
                menu.addItem(item("⏭ 다음 영상", #selector(nextVideo)))
                let plItem = NSMenuItem(title: "재생목록 (\(playlistIndex + 1)/\(playlist.count))", action: nil, keyEquivalent: "")
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
                let qItem = NSMenuItem(title: "화질", action: nil, keyEquivalent: "")
                let qm = NSMenu()
                for (q, label) in [("auto", "자동"), ("highres", "최고 화질 고정"), ("hd1080", "1080p 고정")] {
                    let mi = item(label, #selector(setQuality(_:)))
                    mi.representedObject = q
                    mi.state = q == (wantQuality ?? "auto") ? .on : .off
                    qm.addItem(mi)
                }
                qm.addItem(.separator())
                for (q, label) in qualities where q != "auto" {
                    let mi = item(q == currentQuality ? "\(label) (현재)" : label, #selector(setQuality(_:)))
                    mi.representedObject = q
                    mi.state = q == wantQuality ? .on : .off
                    qm.addItem(mi)
                }
                qItem.submenu = qm
                menu.addItem(qItem)
            }
            if source == .youtube {
                let cc = item("자막", #selector(toggleCaptions))
                cc.state = captionsOn ? .on : .off
                menu.addItem(cc)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("유튜브 링크 열기…", #selector(promptYouTube)))
        menu.addItem(item("쇼츠 피드 보기", #selector(openShortsFeed)))
        menu.addItem(loggedIn ? item("유튜브 로그아웃", #selector(logoutYouTube))
                              : item("유튜브 로그인…", #selector(loginYouTube)))
        menu.addItem(item("영상 파일 열기…", #selector(openFile)))
        menu.addItem(.separator())
        let fill = item("아이콘 꽉 채우기", #selector(toggleFill))
        fill.state = fillMode ? .on : .off
        menu.addItem(fill)
        let show = item("영상 창 보기", #selector(toggleWindow))
        show.state = windowShown ? .on : .off
        menu.addItem(show)
        return menu
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
        appMenu.addItem(NSMenuItem(title: "DockTube 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(NSMenuItem(title: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: - 숨은 영상 창

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
        alert.messageText = "유튜브 링크를 붙여넣으세요"
        alert.informativeText = "Dock 아이콘에서 영상이 재생돼요. 아이콘을 클릭하면 재생/일시정지, 우클릭하면 메뉴가 나와요."

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "영상 또는 재생목록 링크 (…watch?v=… / …playlist?list=…)"
        if let clip = NSPasteboard.general.string(forType: .string),
           videoID(from: clip) != nil || playlistID(from: clip) != nil {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "재생")
        alert.addButton(withTitle: "영상 파일 열기…")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let text = field.stringValue
            let id = videoID(from: text), list = playlistID(from: text)
            if text.contains("/shorts") && list == nil {
                playShorts(id)
            } else if id != nil || list != nil {
                playYouTube(id, list: list)
            } else {
                showMessage("유튜브 링크를 인식하지 못했어요. 주소를 다시 확인해 주세요.")
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
            #"^([A-Za-z0-9_-]{11})$"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t) else { continue }
            return String(t[r])
        }
        return nil
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
                         iv_load_policy:3, disablekb:1, \(captionsOn ? "cc_load_policy:1, cc_lang_pref:'ko'," : "") start:\(start), origin:'\(origin)'},
            events: {
              onReady: function(e){ if (\(isMuted ? "true" : "false")) e.target.mute(); e.target.playVideo(); },
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
                if let next = self.pickNext(from: html) { self.playYouTube(next) } else { self.replayYouTube() }
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

    @objc func prevVideo() { source == .shorts ? swipeShorts(down: false) : webView.evaluateJavaScript("player.previousVideo()") }
    @objc func nextVideo() { source == .shorts ? swipeShorts(down: true) : webView.evaluateJavaScript("player.nextVideo()") }

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
        cfg.snapshotWidth = NSNumber(value: 320)
        cfg.afterScreenUpdates = false
        if source == .shorts {
            guard shortsRect.width > 10, shortsRect.height > 10 else { snapshotInFlight = false; return }
            cfg.rect = shortsRect
        }
        webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self = self else { return }
            self.snapshotInFlight = false
            if self.source == .youtube || self.source == .shorts, let image = image {
                self.setTile(self.compose(image))
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
        setTile(compose(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))))
    }

    // MARK: - 조작

    @objc func togglePlay() {
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
        case .youtube:
            webView.evaluateJavaScript("window.player && player.getDuration ? [player.getCurrentTime(), player.getDuration()] : null") { [weak self] r, _ in
                guard let self = self, self.source == .youtube,
                      let a = r as? [NSNumber], a.count == 2 else { return }
                self.position = a[0].doubleValue
                self.duration = a[1].doubleValue
            }
        case .shorts:
            // 시간·길이·영상 영역을 읽고, 음소거 설정도 맞춰요 (다음 쇼츠로 넘어가면 영상이 바뀌니까 매번)
            webView.evaluateJavaScript("""
            (function(v){ if (!v) return null; v.muted = \(isMuted);
              var r = v.getBoundingClientRect();
              return [v.currentTime, v.duration || 0, r.left, r.top, r.width, r.height]; })(\(Self.shortsVideoJS))
            """) { [weak self] r, _ in
                guard let self = self, self.source == .shorts,
                      let a = (r as? [NSNumber])?.map({ $0.doubleValue }), a.count == 6 else { return }
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
        alert.messageText = "시간 이동"
        alert.informativeText = "슬라이더를 옮긴 뒤 이동을 누르세요."

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
        alert.addButton(withTitle: "이동")
        alert.addButton(withTitle: "취소")
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
        if tickCount % 10 == 0 { updateTime() }  // 재생 시간은 초당 3번이면 충분해요
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

    func showMessage(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
