# VideoSource — شرح هندسي لنظام الاكتشاف والتشغيل الذكي

## الهدف

هذا الملف يشرح لنموذج ذكاء اصطناعي آخر كيف يعمل نظام VideoSource / Auto Source Detector داخل تطبيق `sports_player`.

الهدف ليس مجرد العثور على رابط `.m3u8`. الهدف هو تشغيل الفيديو بأعلى موثوقية ممكنة، واستخدام Native Player فقط عندما توجد أدلة كافية على أن المصدر سيعمل فعليًا، مع إبقاء WebView عندما يكون هو الخيار الأكثر موثوقية.

النظام يتعامل مع:
- JavaScript و SPA
- iframe
- HTML5 video
- HLS و MP4
- روابط بدون امتدادات واضحة
- Fetch / XHR
- CDN مختلف عن دومين الصفحة
- Referer / Origin / User-Agent
- جلسة WebView
- Media Source Extensions
- DRM / EME

ولا يجوز استخدامه لتجاوز DRM أو المصادقة أو الاشتراكات أو أي حماية وصول.

---

## 1. المبدأ الأساسي

لا تستخدم القاعدة:

`وجدت m3u8 = شغله Native`

الصحيح:

`اكتشاف → جمع الأدلة → ترتيب المرشحين → تحقق → Native Trial Gate → اختبار التشغيل الحقيقي → إثبات النجاح`

وعند الفشل:

`Native Failure → Quarantine → WebView → مرشح آخر عند الحاجة`

وعند DRM:

`DRM Detected → WebView Only`

---

## 2. Session State Machine

الإصدارات التي تعتمد على عدة Boolean يمكن أن تدخل في حالات متناقضة.

بدلًا من:

```dart
bool _webDrmDetected;
bool _webDetectionRunning;
bool _webIsPlaying;
bool _nativePlaying;
bool _webLoaded;
```

استخدم حالة واحدة تمثل مصدر الحقيقة:

```dart
enum VideoSessionState {
  loadingPage,
  webReady,
  discovering,
  candidateTrial,
  nativePlaying,
  nativeFailed,
  webFallback,
  drmWebOnly,
  stopped,
}
```

### loadingPage
الصفحة قيد التحميل. يتم فتح WebView وتركيب hooks وتهيئة جلسة جديدة. لا تبدأ Native.

### webReady
الصفحة انتهت ويمكن مراقبتها. ابدأ جمع الأدلة من الفيديو وiframe وPerformance وFetch/XHR.

### discovering
محرك الاكتشاف يبحث عن مصادر محتملة.

### candidateTrial
تم اختيار مرشح قوي ويجري اختباره في Native.

### nativePlaying
ثبت أن Native يشغل الفيديو فعليًا. يجب إيقاف محاولات التحويل غير الضرورية.

### nativeFailed
فشل اختبار Native. يسجل السبب ويضع المصدر في quarantine.

### webFallback
عاد التطبيق إلى WebView بعد فشل Native.

### drmWebOnly
تم اكتشاف DRM. يمنع التحويل إلى Native في الجلسة الحالية.

### stopped
انتهت الجلسة أو تغير المصدر.

---

## 3. Discovery Engine

يجب جمع المرشحين من أكثر من مصدر.

### HTML video

افحص:

```javascript
document.querySelectorAll('video')
```

والقيم:

```text
src
currentSrc
readyState
networkState
paused
currentTime
duration
error
buffered
```

### source elements

```javascript
document.querySelectorAll('video source')
```

### iframe

افحص:

```javascript
document.querySelectorAll('iframe')
```

### Performance

```javascript
performance.getEntriesByType('resource')
```

### Fetch

اعتراض `window.fetch` وتسجيل URL فقط.

### XHR

اعتراض `XMLHttpRequest.prototype.open` وتسجيل URL.

لا تحتاج إلى قراءة أجسام الاستجابات أو استخراج مفاتيح تشفير.

---

## 4. Candidate Intelligence

لا تتعامل مع الرابط كسلسلة نصية فقط.

يفضل أن يمتلك كل Candidate:

```text
url
score
evidence
firstSeen
lastSeen
observedCount
streamType
status
nativeAttempts
lastError
```

مثال:

```json
{
  "url": "https://example.com/live/master.m3u8",
  "score": 175,
  "evidence": ["video.currentSrc", "performance", "fetch"],
  "observedCount": 3,
  "status": "validated"
}
```

زيادة الأدلة تزيد الثقة.

---

## 5. Scoring

نقاط استرشادية:

```text
.m3u8              +100
.mpd                +85
.mp4/.m4v           +55
live                +35
stream              +25
channel             +20
master              +15
playlist            +10
```

وأشياء مثل:

```text
segment
.ts
ads
vast
doubleclick
```

تأخذ خصمًا كبيرًا أو تستبعد.

الـ score لترتيب المرشحين، وليس حكمًا نهائيًا.

---

## 6. WebView Playback Evidence

أقوى دليل ليس وجود URL، بل أن WebView يشغل الفيديو فعلًا.

راقب:

```javascript
video.readyState
video.currentTime
video.paused
video.duration
video.error
video.buffered
video.currentSrc
```

إذا كان:

```text
t=0  currentTime=12.1
t=1  currentTime=12.8
t=2  currentTime=13.6
```

فهذا دليل أن التشغيل يتحرك.

هذا أقوى من مجرد العثور على رابط HLS.

---

## 7. Blob URLs

قد تستخدم صفحات حديثة:

```text
blob:https://site.example/...
```

لا تمرر `blob:` إلى Native.

اعتبره دليلًا على تشغيل WebView، وابحث عن المصدر الحقيقي من الأدلة المتاحة مثل Fetch/XHR/Performance/player configuration.

إذا لم يظهر مصدر عام مناسب لـ Native، ابقَ على WebView.

---

## 8. DRM Detection

راقب:

```javascript
navigator.requestMediaKeySystemAccess
```

وعند اكتشاف نظام DRM أرسل حدثًا مثل:

```javascript
SportsPlayerSource.postMessage(
  JSON.stringify({
    type: "drm_detected",
    system: keySystem
  })
);
```

عند وصول الحدث:

```text
state = drmWebOnly
```

ثم لا تحاول Native في الجلسة الحالية.

ممنوع:
- استخراج مفاتيح DRM
- تجاوز Widevine/FairPlay
- فك التشفير
- تجاوز المصادقة
- تجاوز الاشتراكات أو access controls

---

## 9. Native Trial Gate

لا تنتقل إلى Native بمجرد العثور على URL.

قبل التجربة يجب أن تكون الشروط مناسبة:

1. لا يوجد DRM.
2. المرشح ليس في quarantine.
3. لديه score مناسب.
4. لديه أدلة كافية أو ظهر أكثر من مرة.
5. اجتاز validation قدر الإمكان.
6. لا توجد محاولة Native أخرى.
7. لم نتجاوز حد المحاولات.

ثم:

```text
state = candidateTrial
```

---

## 10. Native Playback Proof

نجاح:

```dart
controller.initialize()
```

ليس دليلًا كافيًا.

يجب إثبات التشغيل الحقيقي:

```text
initialized
+
isPlaying
+
position progresses
```

مثلًا:

```text
position = 10.0
بعد ثانية = 10.7
بعد ثانيتين = 11.5
```

عندها:

```text
state = nativePlaying
```

وإذا لم يتحرك الفيديو أو ظهر خطأ:

```text
state = nativeFailed
```

---

## 11. Failure Quarantine

إذا فشل:

```text
https://example.com/live/master.m3u8
```

سجل المصدر في:

```text
_webFailedNativeSources
```

ولا تعاود تجربته كل ثانيتين.

الهدف منع:

```text
WebView
→ Native
→ Failure
→ WebView
→ Native
→ Failure
```

بلا نهاية.

---

## 12. Native Attempt Limit

ضع حدًا للمحاولات، مثل:

```text
maxNativeAttempts = 2
```

مثال:

```text
Candidate A → failed
Candidate B → failed
→ WebView only
```

لا تجرب عشرات المصادر تلقائيًا.

---

## 13. Single-Flight Detection

لا تسمح بأكثر من detector في نفس الوقت.

مثال:

```dart
bool _webDetectionInFlight = false;
```

قبل الكشف:

```dart
if (_webDetectionInFlight) {
  return;
}
_webDetectionInFlight = true;
```

وفي النهاية:

```dart
_webDetectionInFlight = false;
```

هذا يمنع تداخل Timer أو عمليات async متعددة تسبب التحويل المتكرر.

---

## 14. Session Generation Token

عند بدء جلسة جديدة:

```dart
_sessionGeneration++;
```

كل عملية async تحفظ رقم الجلسة:

```dart
final generation = _sessionGeneration;
```

وقبل تطبيق النتيجة:

```dart
if (generation != _sessionGeneration) {
  return;
}
```

إذا انتقل المستخدم من قناة A إلى B أثناء انتظار عملية تخص A، يتم تجاهل نتيجة A.

هذه طبقة مهمة جدًا لمنع race conditions.

---

## 15. Candidate Registry

يفضل وجود سجل مركزي للمرشحين.

البيانات:

```text
URL
status
score
evidence
observedCount
nativeAttempts
lastError
timestamps
```

حالات المرشح:

```text
seen
validated
trial
nativeFailed
nativeSucceeded
quarantined
```

---

## 16. Validation

بالنسبة إلى HLS يمكن التحقق من:

```text
HTTP response
+
status 2xx
+
#EXTM3U
```

لكن validation ليس حكمًا مطلقًا.

قد يحتاج السيرفر:

```text
Referer
Origin
User-Agent
Cookie
```

وقد يفشل طلب Dart بينما يعمل المصدر داخل WebView.

لذلك يجب ألا تستبدل WebView بنتيجة HTTP سلبية فقط.

---

## 17. Web Context

يمكن التقاط السياق العادي للصفحة:

```javascript
document.referrer
location.origin
navigator.userAgent
```

واستخدام headers عند الحاجة.

لكن لا تنقل Cookies إلى host مختلف بلا تحقق من النطاق.

قاعدة:

> لا ترسل Cookie إلى دومين لا يملكها أو يحتاجها.

---

## 18. لماذا WebView أحيانًا أفضل؟

WebView قد يمتلك:

```text
cookies
JavaScript state
player configuration
session
referer
origin
browser behavior
CDM
```

بينما Native قد يحصل على URL فقط.

لذلك WebView ليس fallback ضعيفًا.

الفلسفة:

> WebView هو الخيار الصحيح عندما تكون الصفحة هي التي تعرف كيف تشغل المحتوى.

وNative هو optimization عندما يكون المصدر العام مناسبًا له.

---

## 19. قاعدة القرار الذهبية

لا تسأل:

```text
هل وجدت رابط فيديو؟
```

اسأل:

```text
هل لدي دليل كافٍ أن Native سيشغل المصدر
بشكل موثوق وأفضل من WebView؟
```

إذا نعم:

```text
Native
```

إذا لا:

```text
WebView
```

---

## 20. الأخطاء

لا تستخدم فقط:

```text
حدث خطأ
```

صنف الخطأ إلى:

```text
network
timeout
404
410
401
403
unsupported
DRM
live window
initialization
playback
unknown
```

مثلًا 403 قد يعني أن المصدر يحتاج سياقًا مثل Referer أو headers، وليس بالضرورة أنه ميت.

---

## 21. Anti-Loop Controller

القواعد الأساسية:

```text
نفس candidate + نفس session
= لا تعاود Native بعد فشل مؤكد
```

و:

```text
native attempts >= limit
= WebView
```

و:

```text
DRM detected
= WebView Only
```

و:

```text
new channel/session
= reset registry
```

---

## 22. عند نجاح Native

عند إثبات التشغيل:

```text
state = nativePlaying
```

ثم أوقف:
- detector timers
- محاولات Native الأخرى
- التحويلات غير الضرورية من WebView

لا تجعل WebView تعود لتخريب تشغيل Native الناجح.

---

## 23. عند فشل Native

الترتيب:

```text
mark candidate failed
↓
quarantine
↓
dispose native controller
↓
state = webFallback
↓
إظهار WebView
↓
إذا يوجد candidate جديد قوي:
    يمكن تجربة واحد آخر
وإلا:
    WebView only
```

لا تعاود تجربة نفس المصدر.

---

## 24. عند تغيير القناة

نفذ reset كامل:

```text
cancel timers
increment session generation
clear candidate registry
clear quarantine
clear DRM state
clear native attempts
clear web context
dispose old native controller
load new WebView
```

---

## 25. ترتيب الأولويات

عند اتخاذ القرار:

1. DRM safety
2. Session validity
3. WebView actual playback
4. Candidate evidence
5. Candidate score
6. Validation
7. Native trial
8. Playback proof
9. Native success

---

## 26. التوافق مع Dashboard

الـ Dashboard يحدد:

```text
streamType = hls
```

أو:

```text
streamType = web
```

في حالة Web:

```text
sourceUrl
```

يدخل إلى WebView، ثم يبدأ Auto Source Engine.

Dashboard لا يحتاج معرفة تفاصيل الاكتشاف.

---

## 27. بنية V3

النظام الأفضل منطقيًا:

```text
WebView
   ↓
Discovery Engine
   ↓
Candidate Intelligence
   ↓
Validation Engine
   ↓
Native Trial Gate
   ↓
Playback Proof
   ↓
Session State Machine
   ↓
Native OR WebView
```

ومعه:

```text
DRM Detection
Failure Quarantine
Anti-Loop
Single-Flight
Session Generation
```

---

## 28. تعليمات لأي نموذج سيعدل المشروع

### لا تفعل

- لا تحذف WebView لصالح Native.
- لا تجعل أي m3u8 ينتقل تلقائيًا إلى Native.
- لا تعاود تجربة نفس الرابط الفاشل بلا حد.
- لا تعتمد على initialize فقط.
- لا تعتمد على Boolean كثيرة متناقضة.
- لا تتجاوز DRM.
- لا تستخرج أو تفك مفاتيح التشفير.
- لا تكسر API الموجود.
- لا تعيد بناء المشروع بالكامل بلا حاجة.

### افعل

- حافظ على أقل تغيير ممكن.
- استخدم State Machine.
- اربط كل async operation بالجلسة.
- استخدم Candidate Registry.
- استخدم evidence-based scoring.
- اختبر التشغيل الحقيقي.
- اجعل WebView fallback من الدرجة الأولى.
- امنع loop.
- سجل سبب القرار داخليًا.

---

## 29. معنى النجاح

لا يمكن ضمان 99% لكل مواقع الإنترنت لأن المواقع الخارجية تتغير وقد تستخدم حماية أو مشغلات خاصة.

لكن يمكن الوصول إلى أعلى موثوقية عملية من خلال:

> لا تحاول إجبار المصدر على Native. دع الأدلة تحدد المشغل المناسب.

إذا كان WebView يشغل الصفحة بنجاح، لا تضحِ بهذا النجاح لمجرد العثور على URL يبدو كأنه HLS.

Native يجب أن يكون ترقية محسوبة، وليس مقامرة.

---

## 30. حالات الاختبار

### HLS عام

```text
WebView
→ detect m3u8
→ validate
→ Native
→ playback proof
→ success
```

### HLS يحتاج headers

```text
WebView works
→ Native trial
→ fails
→ WebView remains
```

### DRM

```text
WebView
→ DRM detected
→ WebView Only
```

### مرشح خاطئ

```text
candidate A
→ native fail
→ quarantine
→ candidate B
→ success
```

### جميع المرشحين يفشلون

```text
A fail
B fail
→ WebView only
```

### تغيير القناة أثناء discovery

```text
Channel A async operation
→ user opens Channel B
→ generation mismatch
→ ignore A result
```

### إعادة تحميل الصفحة

```text
old session
→ reset
→ new session
```

### SPA / Fragment routing

```text
load page
→ JavaScript route
→ wait
→ detect
```

---

## الخلاصة

VideoSource Engine يجب أن يكون:

```text
Evidence Driven
State Driven
Session Safe
Failure Aware
DRM Aware
Loop Resistant
WebView Friendly
Native Opportunistic
```

وليس مجرد URL Finder.

الهدف النهائي:

> تشغيل المحتوى بأقل تدخل من المستخدم، مع الحفاظ على WebView كخيار موثوق، واستخدام Native فقط عندما يثبت أنه مناسب فعلًا.
