import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';

import '../services/ad_service.dart';
import '../services/channel_source_resolver.dart';
import '../services/stream_models.dart';

enum _LoadState { loading, error, ready }

/// One authoritative state machine for a WebView -> Native detection session.
/// It replaces the fragile combination of overlapping booleans/timers.
enum _WebSessionState {
  idle,
  loadingPage,
  webReady,
  interacting,
  discovering,
  candidateTrial,
  nativePlaying,
  nativeFailed,
  drmWebOnly,
  webFallback,
  stopped,
}

class WatchScreen extends StatefulWidget {
  final String? channelId;
  final String? externalUrl;
  final String? externalUserAgent;

  const WatchScreen({
    super.key,
    this.channelId,
    this.externalUrl,
    this.externalUserAgent,
  });

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  WebViewController? _webController;
  bool _isWebSource = false;
  final GlobalKey _videoBoundaryKey = GlobalKey();

  _LoadState _state = _LoadState.loading;
  String _errorMessage = '';
  StreamSession? _session;
  StreamServerOption? _activeServer;
  StreamQuality? _activeQuality;
  Map<String, String>? _headers;

  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _isPlaying = false;
  bool _isBuffering = false;
  Timer? _slowConnectionTimer;
  bool _slowConnectionHint = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 100;
  bool _muted = false;
  bool _fullscreen = false;

  bool _locked = false;
  BoxFit _fit = BoxFit.contain;
  String? _seekFeedback;
  Timer? _seekFeedbackTimer;

  // speed / screenshot
  double _playbackSpeed = 1.0;
  bool _savingScreenshot = false;
  bool _showSpeedSheet = false;

  // swipe
  Offset? _swipeStart;
  bool _seekingFromSwipe = false;

  static const _swipeThreshold = 28.0;
  static const _speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  // ---------------------------------------------------------------------
  // إصلاح جذري لمشكلة "صوت البث خلف الإعلان": يحدث هذا تحديداً عند اختيار
  // قناة جديدة والمشغل يعمل بالفعل في الخلفية (المستخدم فتح قناة، رجع
  // للتطبيق الرئيسي، ثم اختار قناة أخرى). في هذه الحالة تصل الشاشة الجديدة
  // عبر رابط عميق وتستبدل المكدس، لكن شاشة المشاهدة *القديمة* تبقى حيّة
  // (وصوتها يعمل) طوال مدة أنيميشن الانتقال قبل أن يُستدعى dispose() لها —
  // وخلال هذه اللحظة بالذات يظهر إعلان الشاشة الجديدة فيبدو الصوت القديم
  // "خلف" الإعلان. نحتفظ بمرجع ثابت لآخر شاشة مشاهدة نشطة، ونُسكتها فوراً
  // (بشكل متزامن، قبل أي إعلان أو تحميل) بمجرد أن تبدأ شاشة جديدة.
  static _WatchScreenState? _activeInstance;

  Future<void> _stopBeforeInterstitial() async {
    _hideTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      try {
        // لا نعرض الإعلان حتى يؤكد مشغل أندرويد وصول الكتم والإيقاف إليه.
        // استدعاء pause بدون انتظار كان يترك الصوت يعمل للحظات خلف الإعلان.
        await controller.setVolume(0);
        await controller.pause();
      } catch (_) {
        // لو كان المشغل يُغلق أصلاً، لا نمنع المستخدم من متابعة المصدر التالي.
      }
    }
  }

  Future<void> _prepareAndStartPlayback() async {
    final previous = _activeInstance;
    if (previous != null && !identical(previous, this)) {
      await previous._stopBeforeInterstitial();
    }
    if (!mounted) return;

    _activeInstance = this;
    WidgetsBinding.instance.addObserver(this);
    _scheduleHide();

    await AdService.instance.showInterstitialThenProceed(() {
      if (mounted && identical(_activeInstance, this)) _startSession();
    });
  }

  @override
  void initState() {
    super.initState();
    // نوقف المصدر السابق ونتأكد من إيقافه فعلياً قبل فتح الإعلان. ثم لا
    // يبدأ تحميل المصدر الجديد إلا بعد إغلاق الإعلان البيني.
    unawaited(_prepareAndStartPlayback());
  }

  // ---------------------- player listener ----------------------
  void _videoListener() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    final value = controller.value;
    if (value.hasError) {
      setState(() {
        _state = _LoadState.error;
        _errorMessage = 'تعذر تشغيل رابط البث. جرّب مرة أخرى أو غيّر السيرفر.';
      });
      return;
    }
    final wasBuffering = _isBuffering;
    setState(() {
      _isPlaying = value.isPlaying;
      _isBuffering = value.isBuffering;
      _position = value.position;
      _duration = value.duration;
    });
    if (_isBuffering && !wasBuffering) {
      _startSlowConnectionTimer();
    } else if (!_isBuffering && wasBuffering) {
      _cancelSlowConnectionTimer();
    }
  }

  // بدأ تخزين مؤقت جديد — لو استمر أكثر من 6 ثوانٍ متواصلة نعتبرها إشارة
  // على اتصال بطيء ونعرض رسالة توضيحية للمستخدم بدل مؤشر دوّار صامت لا
  // يشرح له السبب. لا نقيس سرعة الشبكة فعلياً (video_player لا يوفرها)،
  // فقط مدة الانتظار كمؤشر تقريبي معقول.
  void _startSlowConnectionTimer() {
    _cancelSlowConnectionTimer();
    _slowConnectionTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && _isBuffering) {
        setState(() => _slowConnectionHint = true);
      }
    });
  }

  void _cancelSlowConnectionTimer() {
    _slowConnectionTimer?.cancel();
    _slowConnectionTimer = null;
    if (_slowConnectionHint) setState(() => _slowConnectionHint = false);
  }

  // ---------------------- session ----------------------
  Future<void> _startSession() async {
    setState(() => _state = _LoadState.loading);

    _headers = (widget.externalUserAgent != null &&
            widget.externalUserAgent!.isNotEmpty)
        ? {'user-agent': widget.externalUserAgent!}
        : null;

    final StreamSession session;
    if (widget.externalUrl != null && widget.externalUrl!.isNotEmpty) {
      final external = widget.externalUrl!.trim();
      final lower = external.toLowerCase();
      final looksLikeVideo = lower.contains('.m3u8') ||
          lower.contains('.mp4') ||
          lower.contains('.m4v') ||
          lower.contains('.mov') ||
          lower.contains('.webm');
      session = StreamSession.success(
        kind: looksLikeVideo ? StreamKind.hls : StreamKind.web,
        isLive: !looksLikeVideo,
        servers: [
          StreamServerOption(
            label: looksLikeVideo ? 'الرابط المُدخل' : 'صفحة البث',
            qualities: [
              StreamQuality(label: looksLikeVideo ? 'تلقائي' : 'صفحة البث', url: external)
            ],
          ),
        ],
      );
    } else if (widget.channelId != null) {
      session = await ChannelSourceResolver.resolve(widget.channelId!);
    } else {
      session = StreamSession.failure('لا يوجد مصدر بث لتشغيله.');
    }

    if (!mounted) return;

    if (!session.ok || session.servers.isEmpty) {
      setState(() {
        _state = _LoadState.error;
        _errorMessage = session.errorMessage ?? 'تعذر تشغيل البث.';
      });
      return;
    }

    _session = session;
    if (session.kind == StreamKind.web) {
      await _openWebSource(session.servers.first.qualities.first.url);
      return;
    }
    await _playServerQuality(
      session.servers.first,
      session.servers.first.qualities.first,
    );
  }

  // ---------------------- web source ----------------------
  String? _webSourceOrigin;
  Timer? _webDetectorTimer;
  _WebSessionState _webSessionState = _WebSessionState.idle;
  int _webSessionGeneration = 0;
  bool _webDetectionInFlight = false;
  int _webNativeAttempts = 0;
  static const int _webMaxNativeAttempts = 2;
  DateTime? _webLastNativeTrialAt;
  final Set<String> _webSeenSources = <String>{};
  final Set<String> _webFailedNativeSources = <String>{};
  final Map<String, int> _webCandidateEvidence = <String, int>{};
  final Map<String, String> _webCandidateLastReason = <String, String>{};
  Map<String, String>? _webContextHeaders;
  bool _webDrmDetected = false;
  String? _webDrmSystem;
  int _webInteractionAttempts = 0;
  static const int _webMaxInteractionAttempts = 3;
  DateTime? _webLastInteractionAt;

  void _setWebSessionState(_WebSessionState next) {
    if (_webSessionState == next) return;
    _webSessionState = next;
  }

  bool _webSessionIsActive(int generation) =>
      mounted && generation == _webSessionGeneration &&
      _webSessionState != _WebSessionState.stopped;

  String _normalizeCandidate(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return url.trim();
    // Keep the full URL by default: query parameters can be security/signing
    // material for live streams. Only normalize casing/fragment noise.
    return uri.replace(fragment: '').toString();
  }

  bool _canTrialNative(String source) {
    if (_webDrmDetected) return false;
    if (_webNativeAttempts >= _webMaxNativeAttempts) return false;
    if (_webFailedNativeSources.contains(source)) return false;
    if (_webSessionState == _WebSessionState.candidateTrial ||
        _webSessionState == _WebSessionState.nativePlaying) return false;
    final last = _webLastNativeTrialAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 2)) {
      return false;
    }
    return true;
  }

  bool _isAllowedWebNavigation(String target) {
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;

    // المواقع الحديثة قد تستخدم CDN أو نطاق مشغل مختلف؛ لا نقفل WebView
    // على نطاق المصدر الأصلي. نمنع فقط نطاقات الإعلانات المعروفة.
    final host = uri.host.toLowerCase();
    return !RegExp(
      r'(doubleclick|googlesyndication|googleadservices|adservice|adnxs|popads|popcash|propellerads|onclick|exoclick|juicyads|trafficjunky|adsterra|outbrain|taboola|mgid|criteo|scorecardresearch)',
      caseSensitive: false,
    ).hasMatch(host);
  }

  Future<void> _installWebProtection(WebViewController controller) async {
    await controller.runJavaScript(r'''(() => {
      try {
        if (window.__sportsPlayerProtectionInstalled) return;
        window.__sportsPlayerProtectionInstalled = true;
        const blocked = (url) => {
          try {
            const u = new URL(url, location.href);
            const h = (u.hostname || '').toLowerCase();
            return /(doubleclick|googlesyndication|googleadservices|adservice|adnxs|popads|popcash|propellerads|onclick|exoclick|juicyads|trafficjunky|adsterra|outbrain|taboola|mgid|criteo|scorecardresearch)/i.test(h);
          } catch (_) { return false; }
        };
        const report = (payload) => {
          try {
            if (window.SportsPlayerSource && window.SportsPlayerSource.postMessage) {
              window.SportsPlayerSource.postMessage(JSON.stringify(payload));
            }
          } catch (_) {}
        };
        const addCandidate = (value) => {
          try {
            if (!value || typeof value !== 'string') return;
            const v = value.trim();
            if (!/^https?:\/\//i.test(v)) return;
            window.__sportsPlayerMediaCandidates = window.__sportsPlayerMediaCandidates || [];
            if (window.__sportsPlayerMediaCandidates.indexOf(v) === -1) {
              window.__sportsPlayerMediaCandidates.push(v);
            }
          } catch (_) {}
        };
        window.open = function(url) {
          if (!url || blocked(url)) return null;
          try {
            const u = new URL(url, location.href);
            if (u.origin !== location.origin) return null;
          } catch (_) { return null; }
          return null;
        };
        document.addEventListener('click', (e) => {
          let el = e.target;
          while (el && el.tagName !== 'A') el = el.parentElement;
          if (!el) return;
          const href = el.getAttribute('href') || '';
          const target = (el.getAttribute('target') || '').toLowerCase();
          if (target === '_blank' || target === '_new' || blocked(href)) {
            e.preventDefault(); e.stopPropagation();
          }
        }, true);
        const style = document.createElement('style');
        style.id = 'sports-player-ad-cleanup';
        style.textContent = `[id*=\"popup\" i],[class*=\"popup\" i],[id*=\"popunder\" i],[class*=\"popunder\" i],[id*=\"advert\" i],[class*=\"advert\" i],[id*=\"adsbox\" i],[class*=\"adsbox\" i],[class*=\"overlay-ad\" i],[class*=\"interstitial\" i]{display:none!important;visibility:hidden!important;}`;
        (document.head || document.documentElement).appendChild(style);

        // DRM/EME detection only. Never bypass DRM or extract keys.
        try {
          const originalRequestMediaKeySystemAccess = navigator.requestMediaKeySystemAccess;
          if (typeof originalRequestMediaKeySystemAccess === 'function' && !navigator.__sportsPlayerEmeHooked) {
            navigator.__sportsPlayerEmeHooked = true;
            navigator.requestMediaKeySystemAccess = function(keySystem, supportedConfigurations) {
              report({type:'drm_detected', system:String(keySystem || 'unknown')});
              return originalRequestMediaKeySystemAccess.apply(this, arguments);
            };
          }
        } catch (_) {}

        // Capture public media/API URLs exposed normally by fetch/XHR.
        try {
          if (window.fetch && !window.__sportsPlayerFetchHooked) {
            window.__sportsPlayerFetchHooked = true;
            const originalFetch = window.fetch;
            window.fetch = function(input, init) {
              try { addCandidate(typeof input === 'string' ? input : (input && input.url)); } catch (_) {}
              return originalFetch.apply(this, arguments).then((response) => {
                try { addCandidate(response && response.url); } catch (_) {}
                return response;
              });
            };
          }
        } catch (_) {}
        try {
          if (window.XMLHttpRequest && !window.__sportsPlayerXhrHooked) {
            window.__sportsPlayerXhrHooked = true;
            const OriginalXHR = window.XMLHttpRequest;
            const originalOpen = OriginalXHR.prototype.open;
            OriginalXHR.prototype.open = function(method, url) {
              try { addCandidate(url); } catch (_) {}
              return originalOpen.apply(this, arguments);
            };
          }
        } catch (_) {}
      } catch (_) {}
    })();''');
  }

  Future<List<String>> _detectPublicMediaSources(WebViewController controller) async {
    try {
      const js = r"""(() => {
        const out = new Set();
        const add = (value) => {
          if (!value || typeof value !== 'string') return;
          const v = value.trim();
          if (!/^https?:\/\//i.test(v)) return;
          const l = v.toLowerCase();
          if (/\.(m3u8|mpd|mp4|m4v|webm|mov)(?:$|[?#])/i.test(v) ||
              /(?:m3u8|manifest|playlist|master|stream|live|hls)(?:[?&=\/]|$)/i.test(l)) out.add(v);
        };
        document.querySelectorAll('video').forEach(v => {
          add(v.currentSrc); add(v.src);
          v.querySelectorAll('source').forEach(s => add(s.src));
        });
        document.querySelectorAll('source').forEach(s => add(s.src));
        document.querySelectorAll('iframe').forEach(f => add(f.src));
        try { performance.getEntriesByType('resource').forEach(e => add(e.name)); } catch (_) {}
        try { (window.__sportsPlayerMediaCandidates || []).forEach(add); } catch (_) {}
        return JSON.stringify(Array.from(out));
      })();""";
      final result = await controller.runJavaScriptReturningResult(js);
      if (result is! String) return const [];
      var text = result;
      if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
        text = text.substring(1, text.length - 1).replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
      }
      final matches = RegExp(r'https?://[^"\s\]]+').allMatches(text);
      return matches.map((m) => m.group(0)!).toList();
    } catch (_) {
      return const [];
    }
  }

  int _scoreDetectedSource(String url) {
    final lower = url.toLowerCase();
    var score = 0;
    if (lower.contains('.m3u8')) score += 100;
    else if (lower.contains('.mpd')) score += 85;
    else if (lower.contains('.mp4') || lower.contains('.m4v') || lower.contains('.webm') || lower.contains('.mov')) score += 55;
    if (lower.contains('live')) score += 35;
    if (lower.contains('stream')) score += 25;
    if (lower.contains('channel')) score += 20;
    if (lower.contains('master')) score += 15;
    if (lower.contains('playlist')) score += 10;
    if (lower.contains('segment') || lower.contains('.ts')) score -= 100;
    if (lower.contains('ads') || lower.contains('advert') || lower.contains('vast') || lower.contains('doubleclick')) score -= 100;
    return score;
  }

  bool _looksLikeHls(String url) => RegExp(r'\.m3u8(?:$|[?#])', caseSensitive: false).hasMatch(url);
  bool _looksLikeProgressiveVideo(String url) => RegExp(r'\.(mp4|m4v|webm|mov)(?:$|[?#])', caseSensitive: false).hasMatch(url);

  Future<bool> _validatePublicMediaSource(String url) async {
    try {
      final uri = Uri.parse(url);
      final headers = <String, String>{
        'user-agent': _headers?['user-agent'] ?? 'Mozilla/5.0 (Android) AppleWebKit/537.36 Chrome/131 Mobile Safari/537.36',
        'accept': '*/*',
      };
      if (_looksLikeHls(url)) {
        final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 8));
        if (response.statusCode < 200 || response.statusCode >= 300) return false;
        final body = response.body;
        return RegExp(r'#EXTM3U', caseSensitive: false).hasMatch(body) ||
            RegExp(r'#EXT-X-(STREAM-INF|TARGETDURATION|MEDIA-SEQUENCE)', caseSensitive: false).hasMatch(body);
      }
      if (_looksLikeProgressiveVideo(url)) {
        final response = await http.head(uri, headers: headers).timeout(const Duration(seconds: 8));
        if (response.statusCode < 200 || response.statusCode >= 400) return false;
        final type = (response.headers['content-type'] ?? '').toLowerCase();
        return type.isEmpty || type.startsWith('video/') || type.contains('octet-stream');
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _captureWebContext(WebViewController controller) async {
    try {
      final result = await controller.runJavaScriptReturningResult(r'''(() => JSON.stringify({
        referer: document.referrer || location.href,
        origin: location.origin || '',
        cookie: document.cookie || '',
        userAgent: navigator.userAgent || ''
      }))();''');
      if (result is! String) return;
      var text = result;
      if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
        text = text.substring(1, text.length - 1).replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
      }
      final data = jsonDecode(text);
      if (data is! Map) return;
      final headers = <String, String>{};
      final ua = data['userAgent']?.toString() ?? '';
      final referer = data['referer']?.toString() ?? '';
      final origin = data['origin']?.toString() ?? '';
      final cookie = data['cookie']?.toString() ?? '';
      if (ua.isNotEmpty) headers['user-agent'] = ua;
      if (referer.startsWith('http')) headers['referer'] = referer;
      if (origin.startsWith('http')) headers['origin'] = origin;
      if (cookie.isNotEmpty) headers['cookie'] = cookie;
      if (mounted && headers.isNotEmpty) _webContextHeaders = headers;
    } catch (_) {}
  }

  Future<bool> _webPlaybackSentinel(WebViewController controller) async {
    try {
      final first = await controller.runJavaScriptReturningResult(r'''(() => {
        const v = document.querySelector('video');
        if (!v) return JSON.stringify({playing:false,time:0});
        return JSON.stringify({playing:!v.paused && v.readyState >= 2,time:v.currentTime || 0});
      })();''');
      final firstText = first is String ? first : first?.toString() ?? '';
      if (!firstText.contains('\"playing\":true')) return false;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted || _webDrmDetected) return false;
      final second = await controller.runJavaScriptReturningResult(r'''(() => {
        const v = document.querySelector('video');
        if (!v) return JSON.stringify({playing:false,time:0});
        return JSON.stringify({playing:!v.paused && v.readyState >= 2,time:v.currentTime || 0});
      })();''');
      final secondText = second is String ? second : second?.toString() ?? '';
      return secondText.contains('\"playing\":true');
    } catch (_) {
      return false;
    }
  }

  Future<bool> _runSmartInteraction(WebViewController controller) async {
    if (_webDrmDetected || _webInteractionAttempts >= _webMaxInteractionAttempts) {
      return false;
    }
    final last = _webLastInteractionAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 2)) {
      return false;
    }
    _webInteractionAttempts++;
    _webLastInteractionAt = DateTime.now();
    _setWebSessionState(_WebSessionState.interacting);

    try {
      final result = await controller.runJavaScriptReturningResult(r'''(() => {
        const normalize = (s) => (s || '').toString().trim().replace(/\s+/g, ' ').toLowerCase();
        const blockedText = /(login|sign[ -]?in|subscribe|subscription|purchase|buy|download|advert|ads|privacy|cookie|close|share|facebook|twitter|telegram|whatsapp)/i;
        const playText = /(play|watch|live|watch live|start|start stream|watch now|تشغيل|مشاهدة|بث مباشر|مشاهدة مباشرة|ابدأ|ابدأ البث|شاهد الآن)/i;
        const isVisible = (el) => {
          if (!el || !el.isConnected) return false;
          const r = el.getBoundingClientRect();
          const st = getComputedStyle(el);
          return r.width >= 24 && r.height >= 24 && r.bottom >= 0 && r.right >= 0 &&
            r.top <= innerHeight && r.left <= innerWidth && st.display !== 'none' &&
            st.visibility !== 'hidden' && st.opacity !== '0' && el.getAttribute('aria-hidden') !== 'true';
        };
        const enabled = (el) => !el.disabled && el.getAttribute('aria-disabled') !== 'true';
        const videoRect = (() => {
          const v = document.querySelector('video');
          return v ? v.getBoundingClientRect() : null;
        })();
        const distanceToVideo = (el) => {
          if (!videoRect) return 0;
          const r = el.getBoundingClientRect();
          const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
          const vx = videoRect.left + videoRect.width / 2, vy = videoRect.top + videoRect.height / 2;
          return Math.hypot(cx - vx, cy - vy);
        };
        const candidates = [];
        const seen = new Set();
        document.querySelectorAll('button,[role=\"button\"],a,[aria-label],[title],input[type=\"button\"],input[type=\"submit\"]').forEach((el) => {
          if (!isVisible(el) || !enabled(el)) return;
          const label = normalize([
            el.getAttribute('aria-label'), el.getAttribute('title'), el.innerText,
            el.textContent, el.getAttribute('data-testid'), el.className
          ].join(' '));
          if (!label || blockedText.test(label) || !playText.test(label)) return;
          const r = el.getBoundingClientRect();
          let score = 0;
          if (playText.test(label)) score += 35;
          if (el.hasAttribute('aria-label')) score += 20;
          if (el.hasAttribute('title')) score += 10;
          if (videoRect) {
            const vr = videoRect;
            const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
            if (cx >= vr.left - 80 && cx <= vr.right + 80 && cy >= vr.top - 80 && cy <= vr.bottom + 80) score += 45;
            if (distanceToVideo(el) < 250) score += 20;
          }
          if (/play|player|video|watch|live/.test(label)) score += 15;
          if (/icon|control|btn|button/.test(label)) score += 5;
          if (el.closest('[id*=\"ad\" i],[class*=\"ad\" i],[id*=\"popup\" i],[class*=\"popup\" i],[id*=\"overlay\" i]')) score -= 100;
          const key = `${el.tagName}|${label}|${Math.round(r.left)}|${Math.round(r.top)}`;
          if (!seen.has(key)) { seen.add(key); candidates.push({el, score, label}); }
        });
        candidates.sort((a,b) => b.score - a.score);
        const best = candidates[0];
        if (!best || best.score < 55) return JSON.stringify({clicked:false, reason:'no-safe-play-control'});
        try {
          best.el.scrollIntoView({block:'center', inline:'center', behavior:'instant'});
          best.el.click();
          return JSON.stringify({clicked:true, score:best.score, label:best.label.slice(0,160)});
        } catch (e) {
          return JSON.stringify({clicked:false, reason:'click-failed'});
        }
      })();''');
      final text = result is String ? result : result?.toString() ?? '';
      if (text.contains('clicked') && text.contains('true')) {
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        if (!mounted || _webDrmDetected) return false;
        final evidence = await controller.runJavaScriptReturningResult(r'''(() => {
          const v = document.querySelector('video');
          if (!v) return JSON.stringify({playing:false, src:''});
          return JSON.stringify({playing:!v.paused && v.readyState >= 2, time:v.currentTime || 0, src:v.currentSrc || v.src || ''});
        })();''');
        final evidenceText = evidence is String ? evidence : evidence?.toString() ?? '';
        return evidenceText.contains('\"playing\":true');
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      if (mounted && _webSessionState == _WebSessionState.interacting) {
        _setWebSessionState(_WebSessionState.webReady);
      }
    }
  }

  Future<void> _autoDetectWebSource(WebViewController controller) async {
    _webDetectorTimer?.cancel();
    final generation = _webSessionGeneration;
    var attempts = 0;
    _setWebSessionState(_WebSessionState.discovering);

    _webDetectorTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!_webSessionIsActive(generation) || attempts++ >= 15) {
        timer.cancel();
        if (_webSessionIsActive(generation) && _webSessionState == _WebSessionState.discovering) {
          _setWebSessionState(_WebSessionState.webReady);
        }
        return;
      }
      // Single-flight guard: a slow HTTP validation must never overlap the next tick.
      if (_webDetectionInFlight || _webSessionState == _WebSessionState.candidateTrial) return;
      if (_webDrmDetected) {
        _setWebSessionState(_WebSessionState.drmWebOnly);
        timer.cancel();
        return;
      }
      if (_webNativeAttempts >= _webMaxNativeAttempts) {
        _setWebSessionState(_WebSessionState.webReady);
        timer.cancel();
        return;
      }

      _webDetectionInFlight = true;
      try {
        // V4 Web Playback Sentinel: if WebView is already playing real media,
        // preserve that success and never force an unnecessary Native switch.
        if (await _webPlaybackSentinel(controller)) {
          if (_webSessionIsActive(generation)) {
            _setWebSessionState(_WebSessionState.webReady);
            timer.cancel();
            _webDetectorTimer = null;
          }
          return;
        }

        final sources = await _detectPublicMediaSources(controller);
        if (!_webSessionIsActive(generation)) return;

        // V4 Smart Interaction: some legitimate players expose no media URL
        // until their real visible Play/Watch control is activated.
        if (sources.isEmpty && _webInteractionAttempts < _webMaxInteractionAttempts) {
          final interacted = await _runSmartInteraction(controller);
          if (interacted) {
            timer.cancel();
            _webDetectorTimer = null;
            _setWebSessionState(_WebSessionState.discovering);
            unawaited(_autoDetectWebSource(controller));
            return;
          }
        }

        for (final sourceRaw in sources) {
          final source = _normalizeCandidate(sourceRaw);
          final score = _scoreDetectedSource(source);
          _webCandidateEvidence[source] = (_webCandidateEvidence[source] ?? 0) + 1;
          if (score < 80) continue;
          final uri = Uri.tryParse(source);
          if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) continue;
          if (source.toLowerCase().contains('.mpd')) continue;
          if (!_canTrialNative(source)) continue;

          // Candidate must be observed more than once OR have a strong HLS signature.
          // This prevents jumping to a transient tracking/segment URL.
          final evidence = _webCandidateEvidence[source] ?? 0;
          final strongHls = _looksLikeHls(source) && score >= 100;
          if (evidence < 2 && !strongHls) continue;

          _setWebSessionState(_WebSessionState.candidateTrial);
          _webNativeAttempts++;
          _webLastNativeTrialAt = DateTime.now();
          _webSeenSources.add(source);
          _webCandidateLastReason[source] = 'validated candidate, evidence=$evidence, score=$score';
          timer.cancel();

          final quality = StreamQuality(label: 'المصدر المكتشف تلقائياً', url: source);
          await _playServerQuality(
            StreamServerOption(label: 'المصدر المكتشف تلقائياً', qualities: [quality]),
            quality,
            fallbackToWeb: true,
          );
          return;
        }
      } finally {
        _webDetectionInFlight = false;
      }
    });
  }


  Future<void> _openWebSource(String url) async {
    _webDetectorTimer?.cancel();
    _webSessionGeneration++;
    _webSessionState = _WebSessionState.loadingPage;
    _webDetectionInFlight = false;
    _webNativeAttempts = 0;
    _webLastNativeTrialAt = null;
    _webInteractionAttempts = 0;
    _webLastInteractionAt = null;
    _webSeenSources.clear();
    _webFailedNativeSources.clear();
    _webCandidateEvidence.clear();
    _webCandidateLastReason.clear();
    setState(() {
      _state = _LoadState.loading;
      _isWebSource = true;
      _webContextHeaders = null;
      _webDrmDetected = false;
      _webDrmSystem = null;
    });
    try {
      final sourceUri = Uri.parse(url);
      _webSourceOrigin = sourceUri.host;
      late final WebViewController controller;
      controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..addJavaScriptChannel(
          'SportsPlayerSource',
          onMessageReceived: (message) {
            try {
              final decoded = jsonDecode(message.message);
              if (decoded is Map && decoded['type'] == 'drm_detected') {
                if (!mounted) return;
                setState(() {
                  _webDrmDetected = true;
                  _webDrmSystem = decoded['system']?.toString();
                });
                _webDetectorTimer?.cancel();
                _setWebSessionState(_WebSessionState.drmWebOnly);
              }
            } catch (_) {}
          },
        )
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (request) {
            if (!request.isMainFrame) return NavigationDecision.navigate;
            return _isAllowedWebNavigation(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) async {
            await _installWebProtection(controller);
            await _captureWebContext(controller);
            if (!mounted) return;
            setState(() => _state = _LoadState.ready);
            if (!_webDrmDetected) {
              _setWebSessionState(_WebSessionState.webReady);
              unawaited(_autoDetectWebSource(controller));
            }
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true && _webSessionState != _WebSessionState.candidateTrial && _webSessionState != _WebSessionState.nativePlaying) {
              setState(() {
                _state = _LoadState.error;
                _errorMessage = 'تعذر فتح صفحة البث. تحقق من الرابط والاتصال بالإنترنت ثم حاول مرة أخرى.';
              });
            }
          },
        ));
      await controller.loadRequest(sourceUri);
      if (!mounted) return;
      _webController = controller;
      setState(() => _state = _LoadState.ready);
      // onPageFinished هو نقطة بدء الكشف الوحيدة. لا نطلق Timer ثانيًا هنا.
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.error;
        _errorMessage = 'تعذر فتح صفحة المصدر. تحقق من الرابط وحاول مرة أخرى.';
      });
    }
  }

  // ---------------------- play ----------------------
  Future<void> _proveNativePlayback(VideoPlayerController controller) async {
    final start = controller.value.position;
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (!controller.value.isInitialized) {
      throw StateError('Native player did not remain initialized.');
    }
    final value = controller.value;
    final advanced = value.position > start || value.position.inMilliseconds > 300;
    if (!value.isPlaying || value.hasError || !advanced) {
      throw StateError('Native playback proof failed.');
    }
  }

  Future<void> _playServerQuality(
      StreamServerOption server, StreamQuality quality, {bool fallbackToWeb = false}) async {
    if (fallbackToWeb) {
      _setWebSessionState(_WebSessionState.candidateTrial);
    }
    setState(() {
      _state = _LoadState.loading;
      _isWebSource = false;
      _activeServer = server;
      _activeQuality = quality;
    });
    try {
      final oldController = _controller;
      oldController?.removeListener(_videoListener);
      await oldController?.dispose();

      final newController = VideoPlayerController.networkUrl(
        Uri.parse(quality.url),
        httpHeaders: {
          ...?_headers,
          ...?_webContextHeaders,
        },
      );
      _controller = newController;
      newController.addListener(_videoListener);
      await newController.initialize();
      await newController.setPlaybackSpeed(_playbackSpeed);
      await newController.setVolume(_muted ? 0 : _volume / 100);
      await newController.play();
      if (fallbackToWeb) {
        await _proveNativePlayback(newController);
      }
      await WakelockPlus.enable();
      if (!mounted) return;
      if (fallbackToWeb) _setWebSessionState(_WebSessionState.nativePlaying);
      setState(() => _state = _LoadState.ready);
    } catch (error) {
      if (!mounted) return;
      if (fallbackToWeb) {
        final failedController = _controller;
        _controller = null;
        try {
          await failedController?.dispose();
        } catch (_) {}
        final failedUrl = _normalizeCandidate(quality.url);
        _webFailedNativeSources.add(failedUrl);
        _webSeenSources.add(failedUrl);
        _webCandidateLastReason[failedUrl] = 'native playback failed: ${_describePlaybackError(error)}';
        _setWebSessionState(_WebSessionState.nativeFailed);
        setState(() {
          _isWebSource = true;
          _state = _LoadState.ready;
          _errorMessage = '';
        });
        // Return to the already-working WebView. A new detector run is only
        // allowed if the session still has budget and cannot reuse this URL.
        final web = _webController;
        if (web != null && _webNativeAttempts < _webMaxNativeAttempts && !_webDrmDetected) {
          _setWebSessionState(_WebSessionState.webFallback);
          Future<void>.delayed(const Duration(milliseconds: 1200), () {
            if (mounted && _isWebSource && !_webDrmDetected &&
                _webSessionState == _WebSessionState.webFallback) {
              unawaited(_autoDetectWebSource(web));
            }
          });
        } else {
          _setWebSessionState(_webDrmDetected
              ? _WebSessionState.drmWebOnly
              : _WebSessionState.webReady);
        }
        return;
      }
      setState(() {
        _state = _LoadState.error;
        _errorMessage = _describePlaybackError(error);
      });
    }
  }

  // يحاول تمييز سبب فشل التشغيل الفعلي من رسالة الاستثناء (video_player
  // يمرّر أخطاء ExoPlayer/AVPlayer الأصلية كما هي تقريباً غالباً) بدل
  // رسالة عامة واحدة تُخفي كل الأسباب المختلفة. تصنيف تقريبي بأفضل جهد
  // اعتماداً على نص الخطأ فقط (لا توجد طريقة أدق متاحة من video_player) —
  // يرجع للرسالة العامة السابقة لو لم يتعرّف على أي نمط معروف.
  String _describePlaybackError(Object error) {
    final text = error.toString().toLowerCase();

    if (text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('network is unreachable') ||
        text.contains('unable to connect') ||
        text.contains('connection refused') ||
        text.contains('connection reset') ||
        text.contains('no route to host')) {
      return 'لا يوجد اتصال بالخادم. تحقق من الإنترنت ثم حاول مرة أخرى.';
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return 'انتهت مهلة الاتصال بالخادم. قد يكون الخادم بطيئًا أو الاتصال غير مستقر.';
    }
    if (text.contains('404') || text.contains('410') || text.contains('not found') || text.contains('gone')) {
      return 'المصدر غير موجود أو انتهت صلاحيته. جرّب سيرفرًا آخر.';
    }
    if (text.contains('403') || text.contains('401') || text.contains('forbidden') || text.contains('unauthorized')) {
      return 'الخادم رفض الوصول إلى هذا المصدر. جرّب سيرفرًا أو جودة أخرى.';
    }
    if (text.contains('unrecognized') || text.contains('unsupported') || text.contains('source error') ||
        text.contains('parsererror') || text.contains('decoder') || text.contains('mime') || text.contains('format')) {
      return 'صيغة هذا المصدر غير مدعومة على جهازك. جرّب سيرفرًا أو جودة أخرى.';
    }
    if (text.contains('behind live window') || text.contains('live window') || text.contains('behindlivewindow')) {
      return 'تعذر الوصول إلى نقطة البث المباشر الحالية. أعد المحاولة أو جرّب سيرفرًا آخر.';
    }
    if (text.contains('drm') || text.contains('widevine') || text.contains('encrypted')) {
      return 'هذا المصدر يستخدم حماية DRM ولا يمكن تشغيله بالمشغل الأصلي.';
    }
    return 'حدث خطأ أثناء تشغيل المصدر. جرّب مرة أخرى أو اختر سيرفرًا آخر.';
  }

  // ---------------------- controls ----------------------
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying && !_locked) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    if (_locked) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    _isPlaying ? controller.pause() : controller.play();
    _scheduleHide();
  }

  void _seekBy(Duration delta) {
    final controller = _controller;
    if (controller == null) return;
    final target = _position + delta;
    controller.seekTo(target < Duration.zero ? Duration.zero : target);
    // كل عملية تقديم/تراجع يدوية تُعطى بداية عدّ جديدة (6 ثوانٍ) لمؤشر
    // "الاتصال بطيء"، بدل ما يتراكم وقت التخزين المؤقت الناتج عن عدة
    // نقرات متتالية على نفس المؤقت القديم فيظهر المؤشر مبكراً وبشكل
    // مضلل وكأن الشبكة بطيئة فعلاً بينما السبب فقط تقديم/تراجع متكرر.
    _cancelSlowConnectionTimer();
    if (_isBuffering) _startSlowConnectionTimer();
    _scheduleHide();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _controller?.setVolume(_muted ? 0 : _volume / 100);
  }

  void _setVolume(double value) {
    setState(() {
      _volume = value;
      _muted = value == 0;
    });
    _controller?.setVolume(_muted ? 0 : value / 100);
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  // نخرج من شاشة المشاهدة: لو فيه شاشة سابقة على المكدس نرجع لها عادي،
  // ولو ما فيه (لأن التطبيق فُتح عبر رابط من تطبيق المحتوى وشاشة المشاهدة
  // هي الشاشة الوحيدة) نغلق تطبيق المشغل بالكامل ونرجع المستخدم مباشرة
  // لتطبيق المحتوى، بدل ما يعلّق على شاشة داخلية فارغة بالمشغل.
  void _exit() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      SystemNavigator.pop();
    }
  }

  void _toggleLock() {
    setState(() => _locked = !_locked);
    if (!_locked) {
      setState(() => _controlsVisible = true);
      _scheduleHide();
    }
  }

  void _toggleFit() {
    setState(
        () => _fit = _fit == BoxFit.contain ? BoxFit.cover : BoxFit.contain);
  }

  void _jumpToLive() {
    final controller = _controller;
    if (controller == null) return;
    if (_duration > Duration.zero) {
      controller.seekTo(_duration);
    }
    if (!_isPlaying) controller.play();
    _scheduleHide();
  }

  Future<void> _changeSpeed(double speed) async {
    await _controller?.setPlaybackSpeed(speed);
    setState(() {
      _playbackSpeed = speed;
      _showSpeedSheet = false;
    });
    _scheduleHide();
  }

  void _openSpeedSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('سرعة التشغيل',
                    style: TextStyle(color: Colors.white70)),
              ),
              ..._speedOptions.map((speed) {
                final selected = speed == _playbackSpeed;
                return ListTile(
                  title: Text(
                    '${speed}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: selected
                      ? const Icon(Icons.check, color: Colors.greenAccent)
                      : null,
                  onTap: () => _changeSpeed(speed),
                );
              }),
            ],
          ),
        );
      },
    ).then((_) {
      if (mounted) setState(() => _showSpeedSheet = false);
    });
  }

  // ---------------------- screenshot ----------------------
  Future<void> _takeScreenshot() async {
    if (_savingScreenshot || _state != _LoadState.ready) return;
    setState(() => _savingScreenshot = true);
    try {
      final boundaryContext = _videoBoundaryKey.currentContext;
      if (boundaryContext == null) throw Exception('فشل التقاط الصورة.');
      final boundary =
          boundaryContext.findRenderObject() as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('فشل التقاط الصورة.');
      final bytes = byteData.buffer.asUint8List();
      if (Platform.isAndroid || Platform.isIOS) {
        final result = await ImageGallerySaverPlus.saveImage(bytes,
            quality: 100, name: 'sports_player_${DateTime.now().millisecondsSinceEpoch}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    result['isSuccess'] == true ? 'تم حفظ الصورة.' : 'تعذر حفظ الصورة.')),
          );
        }
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final saved = File('${dir.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png');
        await saved.writeAsBytes(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم حفظ الصورة في:\n${saved.path}')),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر التقاط صورة.')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingScreenshot = false);
    }
  }

  // ---------------------- gestures ----------------------
  void _handleDoubleTapDown(TapDownDetails details) {
    if (_locked || _state != _LoadState.ready) return;
    final isLive = _session?.isLive ?? false;
    if (isLive) return;
    final width = MediaQuery.of(context).size.width;
    final isRight = details.globalPosition.dx > width / 2;
    _seekBy(Duration(seconds: isRight ? 10 : -10));
    _seekFeedbackTimer?.cancel();
    setState(() => _seekFeedback = isRight ? 'right' : 'left');
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _seekFeedback = null);
    });
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_locked || _state != _LoadState.ready) return;
    final isLive = _session?.isLive ?? false;
    if (isLive) return;
    _swipeStart = details.globalPosition;
    _seekingFromSwipe = false;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_swipeStart == null || _seekingFromSwipe) return;
    final delta = details.globalPosition.dx - _swipeStart!.dx;
    if (delta.abs() > _swipeThreshold) {
      _seekingFromSwipe = true;
      final seconds = (delta / _swipeThreshold).round() * 5;
      _seekBy(Duration(seconds: seconds));
      _seekFeedbackTimer?.cancel();
      setState(() => _seekFeedback = delta > 0 ? 'right' : 'left');
      _seekFeedbackTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _seekFeedback = null);
      });
      _swipeStart = details.globalPosition;
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    _swipeStart = null;
    _seekingFromSwipe = false;
  }

  // سحب رأسي (أي مكان بالشاشة) = تحكم بالصوت. كان مقسّماً سابقاً
  // يمين/يسار (يمين = سطوع)، لكن جزء السطوع لم يكن منفّذاً فعلياً
  // (يرجع فوراً بدون أي تأثير) — أُزيل التقسيم وصار السحب كله للصوت.
  double _dragStartVolume = 0;

  void _onVerticalDragStart(DragStartDetails details) {
    if (_locked || _state != _LoadState.ready) return;
    _swipeStart = details.globalPosition;
    _dragStartVolume = _muted ? 0 : _volume;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_swipeStart == null) return;
    final height = MediaQuery.of(context).size.height;
    final delta = (_swipeStart!.dy - details.globalPosition.dy) / height;
    final newVolume = (_dragStartVolume + delta * 100).clamp(0.0, 100.0);
    _setVolume(newVolume);
    _scheduleHide();
  }

  // ---------------------- sheets ----------------------
  void _openQualitySheet() {
    final session = _session;
    if (session == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (session.hasMultipleServers) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child:
                      Text('السيرفر', style: TextStyle(color: Colors.white70)),
                ),
                ...session.servers.map((server) => ListTile(
                      title: Text(server.label,
                          style: const TextStyle(color: Colors.white)),
                      trailing: server.label == _activeServer?.label
                          ? const Icon(Icons.check, color: Colors.greenAccent)
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        _playServerQuality(server, server.qualities.first);
                      },
                    )),
              ],
              if (_activeServer != null &&
                  _activeServer!.qualities.length > 1) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child:
                      Text('الجودة', style: TextStyle(color: Colors.white70)),
                ),
                ..._activeServer!.qualities.map((quality) => ListTile(
                      title: Text(quality.label,
                          style: const TextStyle(color: Colors.white)),
                      trailing: quality.label == _activeQuality?.label
                          ? const Icon(Icons.check, color: Colors.greenAccent)
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        _playServerQuality(_activeServer!, quality);
                      },
                    )),
              ],
            ],
          ),
        );
      },
    );
  }

  // ---------------------- lifecycle ----------------------
  // يُستدعى كل ما يغيّر التطبيق حالته: يذهب للخلفية، يرجع للمقدمة، أو
  // يُغلق نهائياً. مسؤول عن أمرين:
  // 1) إيقاف الصوت فوراً إذا خرج المستخدم فعلياً من التطبيق (زر الرئيسية،
  //    تبديل تطبيق، إغلاقه) بدل استمرار البث بالخلفية بلا واجهة.
  // 2) استئناف التشغيل تلقائياً عند الرجوع، بشرط أنه كان يعمل فعلاً قبل
  //    الانقطاع (_wasPlayingBeforeBackground) — وهذا هو ما يجعل التشغيل
  //    يرجع تلقائياً بعد إغلاق إعلان AdMob البيني (عرض الإعلان يُخرج
  //    نشاط التطبيق مؤقتاً فيُطلق نفس مسار paused/resumed هذا) بدل ما
  //    يحتاج المستخدم يضغط تشغيل يدوياً بعد كل إعلان.
  bool _wasPlayingBeforeBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        if (controller.value.isPlaying) {
          _wasPlayingBeforeBackground = true;
          controller.pause();
        }
        break;
      case AppLifecycleState.resumed:
        if (_wasPlayingBeforeBackground) {
          _wasPlayingBeforeBackground = false;
          controller.play();
        }
        break;
    }
  }

  @override
  void dispose() {
    _webDetectorTimer?.cancel();
    if (identical(_activeInstance, this)) _activeInstance = null;
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _slowConnectionTimer?.cancel();
    _controller?.removeListener(_videoListener);
    WakelockPlus.disable();
    _controller?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ---------------------- build ----------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onTap: _toggleControls,
          onDoubleTapDown: _handleDoubleTapDown,
          onHorizontalDragStart: _onHorizontalDragStart,
          onHorizontalDragUpdate: _onHorizontalDragUpdate,
          onHorizontalDragEnd: _onHorizontalDragEnd,
          onVerticalDragStart: _onVerticalDragStart,
          onVerticalDragUpdate: _onVerticalDragUpdate,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_state == _LoadState.ready && _isWebSource && _webController != null)
                WebViewWidget(controller: _webController!),
              if (_state == _LoadState.ready && !_isWebSource) Center(child: _buildVideo()),
              if (_state == _LoadState.loading) _buildLoading(),
              if (_state == _LoadState.error) _buildError(),
              if (_state == _LoadState.ready && !_isWebSource && _isBuffering)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              // شارة "الاتصال بطيء" — بركن الشاشة (أسفل يمين)، صغيرة الحجم،
              // بدل ما تكون بمنتصف الشاشة أسفل مؤشر التحميل مباشرة (كانت
              // تحجب جزءاً كبيراً من الصورة وتبدو مزعجة).
              if (_state == _LoadState.ready &&
                  !_isWebSource &&
                  _isBuffering &&
                  _slowConnectionHint)
                Positioned(
                  bottom: 88,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.signal_wifi_statusbar_connected_no_internet_4,
                            color: Colors.white70, size: 13),
                        SizedBox(width: 4),
                        Text('اتصال بطيء',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              // أيقونة تأكيد النقر المزدوج (تقديم/تراجع) — أُبعدت أكثر نحو
              // حافة الشاشة (بدل قرب المنتصف) حتى لا تتراكب مع أزرار
              // التقديم/التراجع اليدوية الدائمة في منتصف الشاشة.
              if (_seekFeedback != null)
                Align(
                  alignment: Alignment(_seekFeedback == 'right' ? 0.78 : -0.78, 0),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: const BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _seekFeedback == 'right'
                          ? Icons.forward_10
                          : Icons.replay_10,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
              if (_state == _LoadState.ready && !_isWebSource && !_locked)
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControls(),
                  ),
                ),
              // زر القفل يبقى ظاهراً دوماً (حتى مع إخفاء بقية التحكمات أو
              // أثناء القفل) عشان المستخدم يقدر دائماً يفتح القفل.
              if (_state == _LoadState.ready && !_isWebSource)
                Positioned(
                  top: 8,
                  left: 8,
                  child: _circleIconButton(
                    icon: _locked ? Icons.lock : Icons.lock_open,
                    tooltip: _locked ? 'إلغاء القفل' : 'قفل الشاشة',
                    onPressed: _toggleLock,
                  ),
                ),
              // speed badge
              if (_state == _LoadState.ready && !_isWebSource && _playbackSpeed != 1.0)
                Positioned(
                  top: 12,
                  left: 56,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_playbackSpeed}x',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final size = controller.value.size;
    final double width = size.width == 0 ? 16.0 : size.width;
    final double height = size.height == 0 ? 9.0 : size.height;
    return RepaintBoundary(
      key: _videoBoundaryKey,
      child: FittedBox(
        fit: _fit,
        child: SizedBox(
          width: width,
          height: height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 12),
          Text('جارٍ التحقق من صلاحية المشاهدة…',
              style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(_errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _startSession,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
                if (_session != null && _session!.hasMultipleServers) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _openQualitySheet,
                    icon: const Icon(Icons.dns),
                    label: const Text('تغيير السيرفر'),
                  ),
                ],
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _exit,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('رجوع'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // زر أيقونة دائري بخلفية شبه شفافة — نمط موحّد لكل أزرار المشغل الآن،
  // بدل IconButton عادي بلا خلفية (كان يصعب تمييزه فوق فيديو فاتح).
  Widget _circleIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    double size = 40,
    double iconSize = 20,
    Widget? child,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.black.withOpacity(0.35),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: child ??
                    Icon(icon, color: Colors.white, size: iconSize),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final isLive = _session?.isLive ?? false;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent, Colors.black87],
          stops: [0, 0.45, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // --------- الشريط العلوي: رجوع + شارة مباشر/الجودة + صوت ---------
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  // مساحة فارغة تعادل عرض زر القفل الثابت (يُرسم فوق هذا
                  // الشريط بشكل منفصل عند top:8,left:8) حتى لا يتراكب معه
                  // زر الرجوع.
                  const SizedBox(width: 48),
                  _circleIconButton(
                    icon: Icons.arrow_back,
                    tooltip: 'رجوع',
                    onPressed: _exit,
                  ),
                  const SizedBox(width: 6),
                  if (isLive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.circle, color: Colors.white, size: 8),
                          SizedBox(width: 5),
                          Text('مباشر',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    )
                  else if (_activeQuality != null)
                    Text(
                      _activeQuality!.label,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                  const Spacer(),
                  if (isLive)
                    _circleIconButton(
                      icon: Icons.live_tv,
                      tooltip: 'القفز للبث المباشر',
                      onPressed: _jumpToLive,
                    ),
                  _circleIconButton(
                    icon: _muted ? Icons.volume_off : Icons.volume_up,
                    tooltip: _muted ? 'إلغاء كتم الصوت' : 'كتم الصوت',
                    onPressed: _toggleMute,
                  ),
                  SizedBox(
                    width: 78,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.5,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                      ),
                      child: Slider(
                        value: _muted ? 0 : _volume,
                        min: 0,
                        max: 100,
                        activeColor: Colors.white,
                        inactiveColor: Colors.white30,
                        onChanged: _setVolume,
                      ),
                    ),
                  ),
                  _circleIconButton(
                    icon: Icons.more_vert,
                    tooltip: 'المزيد من الخيارات',
                    onPressed: _openMoreOptionsSheet,
                  ),
                ],
              ),
            ),
            // --------- منتصف الشاشة: تشغيل/إيقاف + تقديم/تراجع ---------
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isLive)
                    _circleIconButton(
                      icon: Icons.replay_10,
                      tooltip: 'تراجع 10 ثواني',
                      size: 52,
                      iconSize: 28,
                      onPressed: () => _seekBy(const Duration(seconds: -10)),
                    ),
                  const SizedBox(width: 22),
                  _circleIconButton(
                    icon: _isPlaying ? Icons.pause : Icons.play_arrow,
                    tooltip: _isPlaying ? 'إيقاف مؤقت' : 'تشغيل',
                    size: 72,
                    iconSize: 40,
                    onPressed: _togglePlay,
                  ),
                  const SizedBox(width: 22),
                  if (!isLive)
                    _circleIconButton(
                      icon: Icons.forward_10,
                      tooltip: 'تقديم 10 ثواني',
                      size: 52,
                      iconSize: 28,
                      onPressed: () => _seekBy(const Duration(seconds: 10)),
                    ),
                ],
              ),
            ),
            // --------- الشريط السفلي: التقدّم + ملء الشاشة ---------
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 6, 4),
              child: Row(
                children: [
                  if (!isLive) ...[
                    Text(_formatDuration(_position),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14),
                        ),
                        child: Slider(
                          value: _position.inMilliseconds
                              .clamp(
                                  0,
                                  _duration.inMilliseconds == 0
                                      ? 1
                                      : _duration.inMilliseconds)
                              .toDouble(),
                          min: 0,
                          max: _duration.inMilliseconds == 0
                              ? 1
                              : _duration.inMilliseconds.toDouble(),
                          activeColor: Colors.redAccent,
                          inactiveColor: Colors.white30,
                          onChanged: (value) => _controller
                              ?.seekTo(Duration(milliseconds: value.toInt())),
                        ),
                      ),
                    ),
                    Text(_formatDuration(_duration),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ] else
                    const Spacer(),
                  _circleIconButton(
                    icon: _fullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    tooltip:
                        _fullscreen ? 'الخروج من ملء الشاشة' : 'ملء الشاشة',
                    onPressed: _toggleFullscreen,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // قائمة "المزيد" — تجمع الخيارات الثانوية (وضع العرض، الجودة والسيرفر،
  // سرعة التشغيل، التقاط صورة) بورقة سفلية واحدة بدل ازدحام شريط علوي
  // طويل بعدة أيقونات صغيرة، بنفس أسلوب مشغلات الاحتراف.
  void _openMoreOptionsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.aspect_ratio, color: Colors.white),
                title: const Text('وضع العرض',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                  _fit == BoxFit.contain ? 'ملائم للشاشة' : 'تعبئة الشاشة',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleFit();
                },
              ),
              if (_session != null &&
                  (_session!.hasMultipleServers ||
                      _session!.hasMultipleQualities))
                ListTile(
                  leading: const Icon(Icons.hd, color: Colors.white),
                  title: const Text('الجودة والسيرفر',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openQualitySheet();
                  },
                ),
              ListTile(
                leading: const Icon(Icons.speed, color: Colors.white),
                title: const Text('سرعة التشغيل',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text('${_playbackSpeed}x',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openSpeedSheet();
                },
              ),
              ListTile(
                leading: _savingScreenshot
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.camera_alt, color: Colors.white),
                title: const Text('التقاط صورة',
                    style: TextStyle(color: Colors.white)),
                onTap: _savingScreenshot
                    ? null
                    : () {
                        Navigator.pop(sheetContext);
                        _takeScreenshot();
                      },
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}
