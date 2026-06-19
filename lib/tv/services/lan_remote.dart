import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';

/// ============================================================
/// 局域网遥控（扫码）后端
///
/// TV 端起一个内置 HTTP 服务，手机连同一局域网扫码后用浏览器打开
/// 控制页，可：① 编辑设置与服务器配置；② 远程操控播放器
/// （暂停/快进退/上下集/选集/音轨/字幕）。
///
/// - HTTP 服务用 dart:io（无需额外依赖）；局域网 IP 用 NetworkInterface。
/// - 播放器控制走「命令总线」：Web → 后端 → [LanRemoteBus] → 播放页执行。
/// - 播放器状态由播放页写入 [lanRemoteStateProvider]，后端读取回传给 Web。
/// ============================================================

/// 播放器状态快照（播放页每帧写入，Web 轮询读取）。
class LanRemoteState {
  final bool hasItem;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final String title;
  final String type; // Movie / Episode / ...
  final String? seriesId;
  final String? seasonId;
  final List<Map<String, dynamic>> audioTracks; // {id,label,selected}
  final List<Map<String, dynamic>> subtitleTracks;

  const LanRemoteState({
    this.hasItem = false,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.title = '',
    this.type = '',
    this.seriesId,
    this.seasonId,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
  });

  Map<String, dynamic> toJson() => {
        'hasItem': hasItem,
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'title': title,
        'type': type,
        'seriesId': seriesId,
        'seasonId': seasonId,
        'audio': audioTracks,
        'subtitle': subtitleTracks,
      };
}

/// 播放页写入的当前播放状态（无播放时为 null）。
final lanRemoteStateProvider = StateProvider<LanRemoteState?>((ref) => null);

/// 远程命令。
class LanRemoteCommand {
  final String action; // toggle/play/pause/seekRel/seekTo/next/prev/playEpisode/audio/subtitle
  final dynamic value;
  const LanRemoteCommand(this.action, [this.value]);
}

/// 命令总线：后端 send，播放页订阅 stream。
class LanRemoteBus {
  final _controller = StreamController<LanRemoteCommand>.broadcast();
  Stream<LanRemoteCommand> get stream => _controller.stream;
  void send(LanRemoteCommand cmd) {
    if (!_controller.isClosed) _controller.add(cmd);
  }

  void dispose() => _controller.close();
}

final lanRemoteBusProvider = Provider<LanRemoteBus>((ref) {
  final bus = LanRemoteBus();
  ref.onDispose(bus.dispose);
  return bus;
});

final lanRemoteServerProvider = Provider<LanRemoteServer>((ref) {
  final server = LanRemoteServer(ref);
  ref.onDispose(server.stop);
  return server;
});

/// 一条可远程编辑的设置项。
class _Setting {
  final String key;
  final String label;
  final String category;
  final String type; // bool/int/double/enum/string
  final dynamic Function() get;
  final void Function(dynamic) set;
  final Map<String, String>? options;
  final num? min;
  final num? max;

  _Setting({
    required this.key,
    required this.label,
    required this.category,
    required this.type,
    required this.get,
    required this.set,
    this.options,
    this.min,
    this.max,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'category': category,
        'type': type,
        'value': get(),
        if (options != null) 'options': options,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
      };
}

class LanRemoteServer {
  LanRemoteServer(this._ref);

  final Ref _ref;
  HttpServer? _server;
  int _port = 8920;

  bool get isRunning => _server != null;
  int get port => _port;

  /// 返回可访问的局域网 URL（如 http://192.168.1.20:8920）；失败返回 null。
  Future<String?> start({int port = 8920}) async {
    if (_server != null) return urlFor(await _lanIp());
    _port = port;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
    } on SocketException {
      // 端口被占用则自动 +1 重试几次。
      for (var p = port + 1; p < port + 10; p++) {
        try {
          _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
          _port = p;
          break;
        } catch (_) {}
      }
    }
    if (_server == null) return null;
    _server!.listen(_handle, onError: (_) {});
    return urlFor(await _lanIp());
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  String? urlFor(String? ip) => ip == null ? null : 'http://$ip:$_port';

  Future<String?> currentUrl() async => urlFor(await _lanIp());

  Future<String?> _lanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // 优先私有网段地址。
      for (final ni in interfaces) {
        for (final addr in ni.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            return ip;
          }
        }
      }
      // 退而求其次：第一个非回环地址。
      for (final ni in interfaces) {
        for (final addr in ni.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return second >= 16 && second <= 31;
  }

  // ---------------- 请求处理 ----------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    res.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    try {
      final path = req.uri.path;
      if (req.method == 'OPTIONS') {
        res.statusCode = 204;
      } else if (path == '/' || path == '/index.html') {
        res.headers.contentType = ContentType.html;
        res.write(_webPage);
      } else if (path == '/api/state') {
        _json(res, _stateJson());
      } else if (path == '/api/episodes') {
        await _handleEpisodes(req, res);
      } else if (path == '/api/cmd' && req.method == 'POST') {
        await _handleCmd(req, res);
      } else if (path == '/api/setting' && req.method == 'POST') {
        await _handleSetting(req, res);
      } else if (path == '/api/server' && req.method == 'POST') {
        await _handleServer(req, res);
      } else {
        res.statusCode = 404;
        res.write('Not Found');
      }
    } catch (e) {
      res.statusCode = 500;
      res.write(jsonEncode({'error': '$e'}));
    } finally {
      await res.close();
    }
  }

  void _json(HttpResponse res, Object data) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(data));
  }

  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final str = await utf8.decoder.bind(req).join();
    if (str.isEmpty) return {};
    final decoded = jsonDecode(str);
    return decoded is Map<String, dynamic> ? decoded : {};
  }

  Map<String, dynamic> _stateJson() {
    final player = _ref.read(lanRemoteStateProvider);
    return {
      'player': player?.toJson() ?? {'hasItem': false},
      'settings': _settings().map((s) => s.toJson()).toList(),
      'servers': _serversJson(),
    };
  }

  List<Map<String, dynamic>> _serversJson() {
    final servers = _ref.read(serverListProvider);
    final currentId = _ref.read(currentServerProvider)?.id;
    return servers
        .map((s) => {
              'id': s.id,
              'name': s.name,
              'baseUrl': s.baseUrl,
              'remark': s.remark ?? '',
              'iconUrl': s.iconUrl ?? '',
              'activeLineIndex': s.activeLineIndex,
              'current': s.id == currentId,
              'lines': s.lines
                  .map((l) => {
                        'id': l.id,
                        'name': l.name,
                        'url': l.url,
                        'remark': l.remark ?? '',
                      })
                  .toList(),
            })
        .toList();
  }

  Future<void> _handleEpisodes(HttpRequest req, HttpResponse res) async {
    final seriesId = req.uri.queryParameters['seriesId'];
    final seasonId = req.uri.queryParameters['seasonId'];
    if (seriesId == null || seriesId.isEmpty) {
      _json(res, {'episodes': []});
      return;
    }
    try {
      final api = _ref.read(apiClientProvider);
      final episodes = await api.media.getEpisodes(seriesId, seasonId: seasonId);
      _json(res, {
        'episodes': episodes
            .map((e) => {
                  'id': e.id,
                  'name': e.name,
                  'indexNumber': e.indexNumber,
                })
            .toList(),
      });
    } catch (e) {
      _json(res, {'episodes': [], 'error': '$e'});
    }
  }

  Future<void> _handleCmd(HttpRequest req, HttpResponse res) async {
    final body = await _body(req);
    final action = body['action']?.toString() ?? '';
    if (action.isEmpty) {
      res.statusCode = 400;
      return;
    }
    _ref.read(lanRemoteBusProvider).send(
          LanRemoteCommand(action, body['value']),
        );
    _json(res, {'ok': true});
  }

  Future<void> _handleSetting(HttpRequest req, HttpResponse res) async {
    final body = await _body(req);
    final key = body['key']?.toString();
    final spec = _settings().where((s) => s.key == key).firstOrNull;
    if (spec == null) {
      res.statusCode = 404;
      return;
    }
    dynamic val = body['value'];
    switch (spec.type) {
      case 'bool':
        val = val == true || val == 'true';
        break;
      case 'int':
        val = (val is num) ? val.toInt() : int.tryParse('$val') ?? 0;
        break;
      case 'double':
        val = (val is num) ? val.toDouble() : double.tryParse('$val') ?? 0.0;
        break;
      default:
        val = '$val';
    }
    spec.set(val);
    _json(res, {'ok': true});
  }

  Future<void> _handleServer(HttpRequest req, HttpResponse res) async {
    final body = await _body(req);
    final id = body['id']?.toString();
    final notifier = _ref.read(serverListProvider.notifier);
    final servers = _ref.read(serverListProvider);
    final existing = servers.where((s) => s.id == id).firstOrNull;
    if (existing == null) {
      res.statusCode = 404;
      return;
    }
    final linesJson = (body['lines'] as List?) ?? const [];
    final lines = linesJson
        .whereType<Map>()
        .map((l) => ServerLine(
              id: (l['id'] ?? DateTime.now().microsecondsSinceEpoch.toString())
                  .toString(),
              name: (l['name'] ?? '').toString(),
              url: (l['url'] ?? '').toString(),
              remark: (l['remark'] ?? '').toString().isEmpty
                  ? null
                  : l['remark'].toString(),
            ))
        .where((l) => l.url.isNotEmpty)
        .toList();
    final activeIndex = (body['activeLineIndex'] is num)
        ? (body['activeLineIndex'] as num).toInt()
        : existing.activeLineIndex;
    final updated = existing.copyWith(
      name: (body['name'] ?? existing.name).toString(),
      remark: (body['remark'] ?? existing.remark ?? '').toString(),
      iconUrl: (body['iconUrl'] ?? existing.iconUrl ?? '').toString(),
      lines: lines.isEmpty ? existing.lines : lines,
      activeLineIndex: activeIndex,
    );
    notifier.updateServer(updated);
    if (_ref.read(currentServerProvider)?.id == updated.id) {
      _ref.read(currentServerProvider.notifier).state = updated;
    }
    _json(res, {'ok': true});
  }

  // ---------------- 可远程编辑的设置 ----------------

  List<_Setting> _settings() => [
        _Setting(
          key: 'player_core',
          label: '播放器内核',
          category: '播放',
          type: 'enum',
          options: const {
            'nativeMpv': '原生 MPV',
            'mpv': 'MPV (media_kit)',
            'exoPlayer': 'ExoPlayer',
          },
          get: () => _ref.read(playerCoreProvider),
          set: (v) => _ref.read(playerCoreProvider.notifier).state = '$v',
        ),
        _Setting(
          key: 'auto_play_next',
          label: '自动播放下一集',
          category: '播放',
          type: 'bool',
          get: () => _ref.read(autoPlayNextProvider),
          set: (v) => _ref.read(autoPlayNextProvider.notifier).state = v as bool,
        ),
        _Setting(
          key: 'auto_skip',
          label: '自动跳过片头/片尾',
          category: '播放',
          type: 'bool',
          get: () => _ref.read(autoSkipSegmentsProvider),
          set: (v) =>
              _ref.read(autoSkipSegmentsProvider.notifier).state = v as bool,
        ),
        _Setting(
          key: 'hardware_decoding',
          label: '硬件解码',
          category: '播放',
          type: 'bool',
          get: () => _ref.read(hardwareDecodingProvider),
          set: (v) =>
              _ref.read(hardwareDecodingProvider.notifier).state = v as bool,
        ),
        _Setting(
          key: 'skip_step',
          label: '快进/快退步长（秒）',
          category: '播放',
          type: 'int',
          min: 5,
          max: 60,
          get: () => _ref.read(skipForwardStepProvider),
          set: (v) =>
              _ref.read(skipForwardStepProvider.notifier).state = v as int,
        ),
        _Setting(
          key: 'default_speed',
          label: '默认倍速',
          category: '播放',
          type: 'double',
          min: 0.5,
          max: 3.0,
          get: () => _ref.read(defaultPlaybackSpeedProvider),
          set: (v) =>
              _ref.read(defaultPlaybackSpeedProvider.notifier).state =
                  v as double,
        ),
        _Setting(
          key: 'preferred_subtitle_language',
          label: '首选字幕语言',
          category: '字幕',
          type: 'string',
          get: () => _ref.read(preferredSubtitleLanguageProvider),
          set: (v) => _ref
              .read(preferredSubtitleLanguageProvider.notifier)
              .state = '$v',
        ),
        _Setting(
          key: 'preferred_audio_language',
          label: '首选音轨语言',
          category: '音轨',
          type: 'string',
          get: () => _ref.read(preferredAudioLanguageProvider),
          set: (v) =>
              _ref.read(preferredAudioLanguageProvider.notifier).state = '$v',
        ),
        _Setting(
          key: 'watched_threshold',
          label: '看完阈值（%）',
          category: '通用',
          type: 'int',
          min: 75,
          max: 95,
          get: () => _ref.read(watchedThresholdProvider),
          set: (v) =>
              _ref.read(watchedThresholdProvider.notifier).state = v as int,
        ),
        _Setting(
          key: 'background_playback',
          label: '后台播放',
          category: '通用',
          type: 'bool',
          get: () => _ref.read(backgroundPlaybackProvider),
          set: (v) =>
              _ref.read(backgroundPlaybackProvider.notifier).state = v as bool,
        ),
        _Setting(
          key: 'danmaku_enabled',
          label: '弹幕',
          category: '弹幕',
          type: 'bool',
          get: () => _ref.read(danmakuEnabledProvider),
          set: (v) =>
              _ref.read(danmakuEnabledProvider.notifier).state = v as bool,
        ),
      ];

  // ---------------- Web 页面 ----------------

  String get _webPage => _kWebPage;
}

/// 控制页（纯 HTML/CSS/JS，无构建步骤）。
const String _kWebPage = r'''<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/>
<title>LinPlayer 遥控</title>
<style>
  :root{--bg:#121212;--surface:#1e1e1e;--elev:#2a2a2a;--brand:#5b8def;--text:#fff;--sec:#aaa;}
  *{box-sizing:border-box;}
  body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,system-ui,"PingFang SC",sans-serif;padding-bottom:40px;}
  header{position:sticky;top:0;background:var(--surface);display:flex;}
  header button{flex:1;background:none;border:none;color:var(--sec);padding:14px 0;font-size:15px;}
  header button.active{color:var(--brand);border-bottom:2px solid var(--brand);font-weight:600;}
  .tab{display:none;padding:16px;}
  .tab.active{display:block;}
  .card{background:var(--surface);border-radius:10px;padding:14px;margin-bottom:12px;}
  .row{display:flex;align-items:center;justify-content:space-between;gap:10px;margin:10px 0;}
  .title{font-size:15px;} .muted{color:var(--sec);font-size:13px;}
  button.btn{background:var(--elev);color:var(--text);border:none;border-radius:8px;padding:12px;font-size:15px;}
  button.btn:active{background:var(--brand);}
  .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;}
  .grid.three{grid-template-columns:repeat(3,1fr);}
  .big{font-size:20px;padding:18px;}
  input,select{background:var(--elev);color:var(--text);border:1px solid #333;border-radius:8px;padding:10px;font-size:14px;width:100%;}
  .prog{height:6px;background:var(--elev);border-radius:3px;overflow:hidden;margin:8px 0;}
  .prog>div{height:100%;background:var(--brand);width:0;}
  .pill{display:inline-block;background:var(--brand);color:#fff;border-radius:6px;padding:2px 8px;font-size:12px;}
  .list button{display:block;width:100%;text-align:left;margin:6px 0;}
  h3{margin:6px 0 12px;font-size:14px;color:var(--sec);}
  label.sw{position:relative;display:inline-block;width:46px;height:26px;}
  label.sw input{opacity:0;width:0;height:0;}
  .slider{position:absolute;inset:0;background:#444;border-radius:26px;transition:.2s;}
  .slider:before{content:"";position:absolute;height:20px;width:20px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.2s;}
  input:checked+.slider{background:var(--brand);}
  input:checked+.slider:before{transform:translateX(20px);}
</style>
</head>
<body>
<header>
  <button class="tab-btn active" data-t="play">遥控</button>
  <button class="tab-btn" data-t="settings">设置</button>
  <button class="tab-btn" data-t="servers">服务器</button>
</header>

<div id="play" class="tab active">
  <div class="card">
    <div class="title" id="nowTitle">未在播放</div>
    <div class="prog"><div id="bar"></div></div>
    <div class="row"><span class="muted" id="curTime">0:00</span><span class="muted" id="durTime">0:00</span></div>
    <div class="grid">
      <button class="btn" onclick="cmd('seekRel',-60)">-60</button>
      <button class="btn" onclick="cmd('seekRel',-10)">-10</button>
      <button class="btn" onclick="cmd('seekRel',10)">+10</button>
      <button class="btn" onclick="cmd('seekRel',60)">+60</button>
    </div>
    <div class="grid three" style="margin-top:10px;">
      <button class="btn" onclick="cmd('prev')">⏮ 上一集</button>
      <button class="btn big" id="ppBtn" onclick="cmd('toggle')">⏯</button>
      <button class="btn" onclick="cmd('next')">下一集 ⏭</button>
    </div>
  </div>
  <div class="card">
    <div class="row"><b>选集</b><button class="btn" style="width:auto;padding:8px 12px" onclick="loadEpisodes()">刷新</button></div>
    <div id="episodes" class="list"></div>
  </div>
  <div class="card">
    <h3>音轨</h3><div id="audio" class="list"></div>
    <h3>字幕</h3><div id="subs" class="list"></div>
  </div>
</div>

<div id="settings" class="tab"><div id="settingsBody"></div></div>
<div id="servers" class="tab"><div id="serversBody"></div></div>

<script>
let STATE=null, curSeries=null;
function fmt(ms){ms=Math.max(0,ms/1000|0);const m=ms/60|0,s=ms%60;return m+':'+(s<10?'0':'')+s;}
async function cmd(action,value){await fetch('/api/cmd',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,value})});setTimeout(refresh,250);}
async function setSetting(key,value){await fetch('/api/setting',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key,value})});}
async function refresh(){try{const r=await fetch('/api/state');STATE=await r.json();render();}catch(e){}}
document.querySelectorAll('.tab-btn').forEach(b=>b.onclick=()=>{
  document.querySelectorAll('.tab-btn').forEach(x=>x.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));
  b.classList.add('active');document.getElementById(b.dataset.t).classList.add('active');
  if(b.dataset.t==='settings')renderSettings();
  if(b.dataset.t==='servers')renderServers();
});
function render(){
  const p=STATE.player||{};
  document.getElementById('nowTitle').textContent=p.hasItem?p.title:'未在播放';
  document.getElementById('bar').style.width=(p.durationMs?100*p.positionMs/p.durationMs:0)+'%';
  document.getElementById('curTime').textContent=fmt(p.positionMs||0);
  document.getElementById('durTime').textContent=fmt(p.durationMs||0);
  document.getElementById('ppBtn').textContent=p.playing?'⏸':'▶';
  renderTracks('audio',p.audio||[],'audio');
  renderTracks('subs',p.subtitle||[],'subtitle');
  if(p.seriesId&&p.seriesId!==curSeries){curSeries=p.seriesId;loadEpisodes();}
}
function renderTracks(elId,tracks,action){
  const el=document.getElementById(elId);el.innerHTML='';
  tracks.forEach(t=>{const b=document.createElement('button');b.className='btn';
    b.textContent=(t.selected?'● ':'○ ')+t.label;b.onclick=()=>cmd(action,t.id);el.appendChild(b);});
  if(action==='subtitle'){const b=document.createElement('button');b.className='btn';b.textContent='○ 关闭字幕';b.onclick=()=>cmd('subtitle','off');el.appendChild(b);}
}
async function loadEpisodes(){
  const p=STATE&&STATE.player;if(!p||!p.seriesId){document.getElementById('episodes').innerHTML='<div class="muted">非剧集</div>';return;}
  const r=await fetch('/api/episodes?seriesId='+encodeURIComponent(p.seriesId)+(p.seasonId?'&seasonId='+encodeURIComponent(p.seasonId):''));
  const d=await r.json();const el=document.getElementById('episodes');el.innerHTML='';
  (d.episodes||[]).forEach(e=>{const b=document.createElement('button');b.className='btn';
    b.textContent=(e.indexNumber?('第'+e.indexNumber+'集 · '):'')+e.name;b.onclick=()=>cmd('playEpisode',e.id);el.appendChild(b);});
}
function renderSettings(){
  if(!STATE)return;const body=document.getElementById('settingsBody');const cats={};
  (STATE.settings||[]).forEach(s=>{(cats[s.category]=cats[s.category]||[]).push(s);});
  body.innerHTML='';
  Object.keys(cats).forEach(cat=>{
    const card=document.createElement('div');card.className='card';card.innerHTML='<h3>'+cat+'</h3>';
    cats[cat].forEach(s=>{
      const row=document.createElement('div');row.className='row';
      const lab=document.createElement('span');lab.className='title';lab.textContent=s.label;row.appendChild(lab);
      let ctl;
      if(s.type==='bool'){ctl=document.createElement('label');ctl.className='sw';
        ctl.innerHTML='<input type="checkbox" '+(s.value?'checked':'')+'><span class="slider"></span>';
        ctl.querySelector('input').onchange=e=>setSetting(s.key,e.target.checked);}
      else if(s.type==='enum'){ctl=document.createElement('select');ctl.style.width='55%';
        Object.entries(s.options).forEach(([v,l])=>{const o=document.createElement('option');o.value=v;o.textContent=l;if(v===s.value)o.selected=true;ctl.appendChild(o);});
        ctl.onchange=e=>setSetting(s.key,e.target.value);}
      else{ctl=document.createElement('input');ctl.style.width='40%';
        ctl.type=(s.type==='int'||s.type==='double')?'number':'text';ctl.value=s.value;
        if(s.min!=null)ctl.min=s.min;if(s.max!=null)ctl.max=s.max;if(s.type==='double')ctl.step='0.1';
        ctl.onchange=e=>setSetting(s.key,s.type==='string'?e.target.value:parseFloat(e.target.value));}
      row.appendChild(ctl);card.appendChild(row);
    });
    body.appendChild(card);
  });
}
function renderServers(){
  if(!STATE)return;const body=document.getElementById('serversBody');body.innerHTML='';
  (STATE.servers||[]).forEach(sv=>{
    const card=document.createElement('div');card.className='card';
    card.innerHTML='<div class="row"><b>'+(sv.current?'<span class="pill">当前</span> ':'')+'</b></div>';
    card.appendChild(field('名称',sv.name,v=>sv.name=v));
    card.appendChild(field('备注',sv.remark,v=>sv.remark=v));
    card.appendChild(field('图标地址',sv.iconUrl,v=>sv.iconUrl=v));
    const lh=document.createElement('h3');lh.textContent='线路（当前第 '+(sv.activeLineIndex+1)+' 条）';card.appendChild(lh);
    sv.lines.forEach((ln,i)=>{
      card.appendChild(field('线路'+(i+1)+'名称',ln.name,v=>ln.name=v));
      card.appendChild(field('线路'+(i+1)+'地址',ln.url,v=>ln.url=v));
      const act=document.createElement('button');act.className='btn';act.style.marginBottom='8px';
      act.textContent=(i===sv.activeLineIndex?'● 当前线路':'设为当前线路');act.onclick=()=>{sv.activeLineIndex=i;renderServers();};card.appendChild(act);
    });
    const save=document.createElement('button');save.className='btn';save.textContent='保存';
    save.onclick=async()=>{await fetch('/api/server',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(sv)});save.textContent='已保存 ✓';setTimeout(refresh,400);};
    card.appendChild(save);body.appendChild(card);
  });
}
function field(label,val,onChange){
  const w=document.createElement('div');w.style.margin='8px 0';
  const l=document.createElement('div');l.className='muted';l.textContent=label;
  const i=document.createElement('input');i.value=val||'';i.onchange=e=>onChange(e.target.value);
  w.appendChild(l);w.appendChild(i);return w;
}
refresh();setInterval(refresh,1500);
</script>
</body>
</html>''';
