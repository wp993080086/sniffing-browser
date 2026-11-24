import 'package:xml/xml.dart' as xml;

import 'mpd_models.dart';

class MpdParseException implements Exception {
  const MpdParseException(this.message);

  final String message;

  @override
  String toString() => 'MpdParseException: $message';
}

/// MPD 解析器。
///
/// 只处理点播（static）流：live 流没有固定分片数，下到一半窗口就滑走了，
/// 拿到的文件多半不完整，这里直接拒绝而不是假装成功。
class MpdParser {
  const MpdParser();

  MpdManifest parse(String text, {required Uri baseUri}) {
    final xml.XmlDocument document;
    try {
      document = xml.XmlDocument.parse(text);
    } on xml.XmlException catch (e) {
      throw MpdParseException('MPD 不是合法 XML：${e.message}');
    }

    final xml.XmlElement root = document.rootElement;
    if (root.name.local != 'MPD') {
      throw MpdParseException('根节点不是 MPD，实际是 ${root.name.local}');
    }

    final Duration? presentationDuration = parseDuration(
      _attr(root, 'mediaPresentationDuration'),
    );
    final List<Uri> rootBases = _baseUrls(root, <Uri>[baseUri]);
    final MpdSegmentInfo? rootSegment = _segmentInfo(root);

    final List<MpdPeriod> periods = <MpdPeriod>[];
    final List<xml.XmlElement> periodNodes = _childrenNamed(
      root,
      'Period',
    ).toList();
    for (final xml.XmlElement node in periodNodes) {
      final List<Uri> periodBases = _baseUrls(node, rootBases);
      final MpdSegmentInfo own = _segmentInfo(node) ?? const MpdSegmentInfo();
      final MpdSegmentInfo periodSegment = _inherit(own, rootSegment);

      final List<MpdAdaptationSet> adaptations = <MpdAdaptationSet>[];
      for (final xml.XmlElement a in _childrenNamed(node, 'AdaptationSet')) {
        final List<Uri> aBases = _baseUrls(a, periodBases);
        final MpdSegmentInfo aSegment = _inherit(
          _segmentInfo(a),
          periodSegment,
        );
        final List<MpdRepresentation> representations = <MpdRepresentation>[];

        for (final xml.XmlElement r in _childrenNamed(a, 'Representation')) {
          final List<Uri> rBases = _baseUrls(r, aBases);
          representations.add(
            MpdRepresentation(
              id: _attr(r, 'id') ?? '0',
              bandwidth: _int(_attr(r, 'bandwidth')),
              width: _int(_attr(r, 'width')),
              height: _int(_attr(r, 'height')),
              mimeType: _attr(r, 'mimeType') ?? _attr(a, 'mimeType'),
              codecs: _attr(r, 'codecs') ?? _attr(a, 'codecs'),
              lang: _attr(r, 'lang') ?? _attr(a, 'lang'),
              baseUrls: rBases,
              segment: _segmentInfo(r),
            ),
          );
        }

        adaptations.add(
          MpdAdaptationSet(
            mimeType: _attr(a, 'mimeType'),
            contentType: _attr(a, 'contentType'),
            codecs: _attr(a, 'codecs'),
            lang: _attr(a, 'lang'),
            baseUrls: aBases,
            segment: aSegment,
            representations: representations,
            protected:
                _childrenNamed(a, 'ContentProtection').isNotEmpty ||
                _childrenNamed(node, 'ContentProtection').isNotEmpty,
          ),
        );
      }

      periods.add(
        MpdPeriod(
          duration:
              parseDuration(_attr(node, 'duration')) ??
              (periodNodes.length == 1 ? presentationDuration : null),
          baseUrls: periodBases,
          segment: periodSegment,
          adaptations: adaptations,
        ),
      );
    }

    if (periods.isEmpty) {
      throw MpdParseException('MPD 里没有 Period');
    }

    return MpdManifest(
      baseUri: baseUri,
      mediaPresentationDuration: presentationDuration,
      baseUrls: rootBases,
      segment: rootSegment,
      periods: periods,
    );
  }

  /// 从所有 Period 里挑最高码率的视频轨和音频轨。
  ///
  /// [videoId] / [audioId] 给定时按 id 精确取，取不到就退回「挑最好的」——
  /// 用户选过之后 MPD 变了（多码率站点会重排），不该让整个下载失败。
  MpdSelectedTracks selectTracks(
    MpdManifest manifest, {
    String? videoId,
    String? audioId,
  }) {
    final List<MpdSelectedTrack> all = listTracks(manifest);
    MpdSelectedTrack? video;
    MpdSelectedTrack? audio;
    // 命中用户指定的 id 之后就锁住，别再被「更好的那条」覆盖回去。
    bool videoLocked = false;
    bool audioLocked = false;

    for (final MpdSelectedTrack track in all) {
      if (track.kind == DashTrackKind.video) {
        if (videoId != null && track.id == videoId) {
          video = track;
          videoLocked = true;
        } else if (!videoLocked && _better(track, video)) {
          video = track;
        }
      } else {
        if (audioId != null && track.id == audioId) {
          audio = track;
          audioLocked = true;
        } else if (!audioLocked && _better(track, audio)) {
          audio = track;
        }
      }
    }

    if (video == null && audio == null) {
      throw const MpdParseException('MPD 里找不到可下载的音视频轨（可能全是字幕或受保护内容）');
    }
    return MpdSelectedTracks(video: video, audio: audio);
  }

  /// 列出所有可下载的音视频轨，供「下载前选择清晰度 / 音轨」用。
  List<MpdSelectedTrack> listTracks(MpdManifest manifest) {
    final List<MpdSelectedTrack> result = <MpdSelectedTrack>[];
    final Set<String> seen = <String>{};

    for (final MpdPeriod period in manifest.periods) {
      for (final MpdAdaptationSet adaptation in period.adaptations) {
        if (adaptation.protected) {
          throw const MpdParseException(
            '这个 DASH 流带 DRM 保护，无法下载（浏览器能播是因为它有播放授权）',
          );
        }
        final DashTrackKind? inheritedKind = _kindOf(
          mimeType: adaptation.mimeType,
          contentType: adaptation.contentType,
          codecs: adaptation.codecs,
        );

        for (final MpdRepresentation representation
            in adaptation.representations) {
          final DashTrackKind? kind = _kindOf(
            mimeType: representation.mimeType,
            contentType: adaptation.contentType,
            codecs: representation.codecs,
            inherited: inheritedKind,
          );
          if (kind == null) continue;

          MpdSegmentInfo? segment = representation.segment;
          for (final MpdSegmentInfo? parent in <MpdSegmentInfo?>[
            adaptation.segment,
            period.segment,
            manifest.segment,
          ]) {
            if (parent == null) continue;
            segment = segment == null ? parent : segment.inheritFrom(parent);
          }
          if (segment == null) {
            throw MpdParseException(
              'Representation ${representation.id} 没有分片地址（SegmentTemplate/SegmentList）',
            );
          }

          final Uri base = _base(representation.baseUrls, manifest.baseUri);
          // 多 Period 的流里同一条轨会重复出现，用 id 去重。
          if (!seen.add('${kind.name}:${representation.id}')) continue;
          result.add(
            MpdSelectedTrack(
              kind: kind,
              id: representation.id,
              baseUri: base,
              segment: segment,
              periodDuration: period.duration,
              bandwidth: representation.bandwidth,
              width: representation.width,
              height: representation.height,
              codecs: representation.codecs ?? adaptation.codecs,
              lang: representation.lang ?? adaptation.lang,
            ),
          );
        }
      }
    }
    return result;
  }

  /// 把模板里的 `$Number$` / `$Time$` / `$RepresentationID$` 换成实际值。
  String expandTemplate(
    String template, {
    required String representationId,
    required int number,
    int? time,
    int? bandwidth,
  }) {
    return template.replaceAllMapped(
      RegExp(r'\$(?:\$|([A-Za-z]+))(?:%0(\d+)d)?\$'),
      (Match match) {
        if (match.group(1) == null) return '\$';
        final String width = match.group(2) ?? '';
        final String name = match.group(1)!;
        switch (name) {
          case 'RepresentationID':
            return representationId;
          case 'Number':
            return _padded('$number', width);
          case 'Time':
            return _padded('${time ?? 0}', width);
          case 'Bandwidth':
            return _padded('${bandwidth ?? 0}', width);
          case 'SubNumber':
            return _padded('$number', width);
          default:
            // 不认识的占位符原样保留，让 404 自己说话，比猜错值好排查。
            return match.group(0)!;
        }
      },
    );
  }

  /// ISO 8601 时长（`PT5M30S`），也兼容个别站点直接写秒数。
  static Duration? parseDuration(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final String value = raw.trim();
    if (RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value)) {
      return Duration(microseconds: (double.parse(value) * 1000000).round());
    }
    final RegExpMatch? match = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    ).firstMatch(value);
    if (match == null) return null;
    final int days = int.tryParse(match.group(1) ?? '0') ?? 0;
    final int hours = int.tryParse(match.group(2) ?? '0') ?? 0;
    final int minutes = int.tryParse(match.group(3) ?? '0') ?? 0;
    final double seconds = double.tryParse(match.group(4) ?? '0') ?? 0;
    return Duration(
      days: days,
      hours: hours,
      minutes: minutes,
      microseconds: (seconds * 1000000).round(),
    );
  }

  static bool _better(MpdSelectedTrack candidate, MpdSelectedTrack? current) {
    if (current == null) return true;
    final int a = candidate.bandwidth ?? 0;
    final int b = current.bandwidth ?? 0;
    if (a != b) return a > b;
    final int pa = (candidate.width ?? 0) * (candidate.height ?? 0);
    final int pb = (current.width ?? 0) * (current.height ?? 0);
    return pa > pb;
  }

  static DashTrackKind? _kindOf({
    String? mimeType,
    String? contentType,
    String? codecs,
    DashTrackKind? inherited,
  }) {
    final String mime = (mimeType ?? '').toLowerCase();
    final String type = (contentType ?? '').toLowerCase();
    final String codec = (codecs ?? '').toLowerCase();
    if (mime.startsWith('video/') || type == 'video') {
      return DashTrackKind.video;
    }
    if (mime.startsWith('audio/') || type == 'audio') {
      return DashTrackKind.audio;
    }
    if (inherited != null) return inherited;
    if (RegExp(r'^(avc1|avc3|hvc1|hev1|vp09|av01|mp4v)').hasMatch(codec)) {
      return DashTrackKind.video;
    }
    if (RegExp(r'^(mp4a|ac-3|ec-3|opus|flac|mp3)').hasMatch(codec)) {
      return DashTrackKind.audio;
    }
    return null;
  }

  static String _padded(String value, String width) {
    if (width.isEmpty) return value;
    final int count = int.tryParse(width) ?? 0;
    return count <= 0 ? value : value.padLeft(count, '0');
  }

  static MpdSegmentInfo _inherit(
    MpdSegmentInfo? child,
    MpdSegmentInfo? parent,
  ) {
    if (parent == null) return child ?? const MpdSegmentInfo();
    return child == null ? parent : child.inheritFrom(parent);
  }

  static List<Uri> _baseUrls(xml.XmlElement node, List<Uri> parentBases) {
    final Uri parent = parentBases.isEmpty ? Uri.base : parentBases.last;
    final List<Uri> result = <Uri>[];
    for (final xml.XmlElement element in _childrenNamed(node, 'BaseURL')) {
      final String text = element.innerText.trim();
      final String? value = text.isEmpty ? null : text;
      if (value == null) continue;
      result.add(parent.resolve(value));
    }
    return result.isEmpty ? parentBases : result;
  }

  static Uri _base(List<Uri> bases, Uri fallback) =>
      bases.isEmpty ? fallback : bases.first;

  static MpdSegmentInfo? _segmentInfo(xml.XmlElement node) {
    final xml.XmlElement? template = _childNamed(node, 'SegmentTemplate');
    final xml.XmlElement? list = _childNamed(node, 'SegmentList');
    final xml.XmlElement? base = _childNamed(node, 'SegmentBase');
    if (template == null && list == null && base == null) return null;

    final xml.XmlElement? timeline = template == null
        ? null
        : _childNamed(template, 'SegmentTimeline');
    final List<MpdTimelineEntry> entries = <MpdTimelineEntry>[];
    if (timeline != null) {
      for (final xml.XmlElement s in _childrenNamed(timeline, 'S')) {
        final int? duration = _int(_attr(s, 'd'));
        if (duration == null || duration <= 0) continue;
        entries.add(
          MpdTimelineEntry(
            t: _int(_attr(s, 't')),
            d: duration,
            r: _int(_attr(s, 'r')) ?? 0,
          ),
        );
      }
    }

    final List<String> media = <String>[];
    String? init;
    if (list != null) {
      final xml.XmlElement? initNode = _childNamed(list, 'Initialization');
      init = initNode == null ? null : _attr(initNode, 'sourceURL');
      for (final xml.XmlElement s in _childrenNamed(list, 'SegmentURL')) {
        final String? url = _attr(s, 'media');
        if (url != null) media.add(url);
      }
    }

    return MpdSegmentInfo(
      template: template == null
          ? null
          : MpdSegmentTemplate(
              initialization:
                  _attr(template, 'initialization') ?? _attr(template, 'init'),
              media: _attr(template, 'media'),
              startNumber: _int(_attr(template, 'startNumber')) ?? 1,
              timescale: _int(_attr(template, 'timescale')) ?? 1,
              duration: _int(_attr(template, 'duration')),
              timeline: entries,
            ),
      list: list == null
          ? null
          : MpdSegmentList(initialization: init, media: media),
      hasSegmentBase: base != null,
    );
  }

  static Iterable<xml.XmlElement> _childrenNamed(
    xml.XmlElement node,
    String name,
  ) {
    return node.childElements.where((xml.XmlElement e) => e.name.local == name);
  }

  static xml.XmlElement? _childNamed(xml.XmlElement node, String name) {
    for (final xml.XmlElement e in node.childElements) {
      if (e.name.local == name) return e;
    }
    return null;
  }

  static String? _attr(xml.XmlElement node, String name) {
    for (final xml.XmlAttribute a in node.attributes) {
      if (a.localName == name) return a.value;
    }
    return null;
  }

  static int? _int(String? value) {
    if (value == null) return null;
    return int.tryParse(value.trim());
  }
}
