/// DASH/MPD 的数据模型。
///
/// 只覆盖「把一条已完成（非 live）的点播流下载下来」需要的字段。
/// 不追求 DASH-IF 完整实现：SegmentBase 单文件封装和 DRM 会明确报错，
/// 而不是拼出一个看着像 mp4 实际播不了的坏文件。
library;

/// 轨道类型。DASH 把画面和声音拆成两条独立的 Representation。
enum DashTrackKind { video, audio }

/// MPD 里的一条时长轴条目：`<S t="..." d="..." r="..."/>`。
class MpdTimelineEntry {
  const MpdTimelineEntry({
    this.t,
    required this.d,
    this.r = 0,
  });

  /// 起点的 timescale 单位。空表示接在上一条末尾。
  final int? t;

  /// 时长（timescale 单位）。
  final int d;

  /// 重复次数。-1 表示无界（live 流），本项目不支持。
  final int r;
}

/// `$Number$` / `$Time$` 模板。
class MpdSegmentTemplate {
  const MpdSegmentTemplate({
    this.initialization,
    this.media,
    this.startNumber = 1,
    this.timescale = 1,
    this.duration,
    this.timeline = const <MpdTimelineEntry>[],
  });

  final String? initialization;
  final String? media;
  final int startNumber;
  final int timescale;
  final int? duration;
  final List<MpdTimelineEntry> timeline;

  /// 子层（Representation）的模板可以只写一部分，其余继承父层。
  MpdSegmentTemplate inheritFrom(MpdSegmentTemplate parent) {
    return MpdSegmentTemplate(
      initialization: initialization ?? parent.initialization,
      media: media ?? parent.media,
      startNumber: startNumber == 1 && parent.startNumber != 1
          ? parent.startNumber
          : startNumber,
      timescale: timescale == 1 && parent.timescale != 1
          ? parent.timescale
          : timescale,
      duration: duration ?? parent.duration,
      timeline: timeline.isEmpty ? parent.timeline : timeline,
    );
  }
}

/// `<SegmentList>`：分片地址逐个列出，没有模板。
class MpdSegmentList {
  const MpdSegmentList({
    this.initialization,
    this.media = const <String>[],
  });

  final String? initialization;
  final List<String> media;

  MpdSegmentList inheritFrom(MpdSegmentList parent) => MpdSegmentList(
        initialization: initialization ?? parent.initialization,
        media: media.isEmpty ? parent.media : media,
      );
}

/// 一条 Representation 最终继承到的分片寻址方式。
class MpdSegmentInfo {
  const MpdSegmentInfo({
    this.template,
    this.list,
    this.hasSegmentBase = false,
  });

  final MpdSegmentTemplate? template;
  final MpdSegmentList? list;

  /// `<SegmentBase>` 把 init + 所有分片放在同一个文件里，靠字节区间取。
  /// 需要 HTTP Range 拼装 moof 索引，本项目明确不支持。
  final bool hasSegmentBase;

  MpdSegmentInfo inheritFrom(MpdSegmentInfo parent) {
    return MpdSegmentInfo(
      template: template == null
          ? parent.template
          : template!.inheritFrom(parent.template ?? const MpdSegmentTemplate()),
      list: list == null
          ? parent.list
          : list!.inheritFrom(parent.list ?? const MpdSegmentList()),
      hasSegmentBase: hasSegmentBase || parent.hasSegmentBase,
    );
  }
}

class MpdRepresentation {
  const MpdRepresentation({
    required this.id,
    this.bandwidth,
    this.width,
    this.height,
    this.mimeType,
    this.codecs,
    this.baseUrls = const <Uri>[],
    this.segment,
  });

  final String id;
  final int? bandwidth;
  final int? width;
  final int? height;
  final String? mimeType;
  final String? codecs;
  final List<Uri> baseUrls;
  final MpdSegmentInfo? segment;
}

class MpdAdaptationSet {
  const MpdAdaptationSet({
    this.mimeType,
    this.contentType,
    this.codecs,
    this.baseUrls = const <Uri>[],
    this.segment,
    this.representations = const <MpdRepresentation>[],
    this.protected = false,
  });

  final String? mimeType;
  final String? contentType;
  final String? codecs;
  final List<Uri> baseUrls;
  final MpdSegmentInfo? segment;
  final List<MpdRepresentation> representations;

  /// 出现过 `<ContentProtection>`。带 DRM 的流拼出来也放不了，提前拦住。
  final bool protected;
}

class MpdPeriod {
  const MpdPeriod({
    this.duration,
    this.baseUrls = const <Uri>[],
    this.segment,
    this.adaptations = const <MpdAdaptationSet>[],
  });

  final Duration? duration;
  final List<Uri> baseUrls;
  final MpdSegmentInfo? segment;
  final List<MpdAdaptationSet> adaptations;
}

class MpdManifest {
  const MpdManifest({
    required this.baseUri,
    this.mediaPresentationDuration,
    this.baseUrls = const <Uri>[],
    this.segment,
    this.periods = const <MpdPeriod>[],
  });

  /// mpd 文件自身的地址。所有相对路径以它为基准。
  final Uri baseUri;
  final Duration? mediaPresentationDuration;
  final List<Uri> baseUrls;
  final MpdSegmentInfo? segment;
  final List<MpdPeriod> periods;

  bool get isDynamic => mediaPresentationDuration == null;
}

/// 选中后的轨道：已经把父层的 BaseURL 和 SegmentTemplate 继承下来。
class MpdSelectedTrack {
  const MpdSelectedTrack({
    required this.kind,
    required this.id,
    required this.baseUri,
    required this.segment,
    required this.periodDuration,
    this.bandwidth,
    this.width,
    this.height,
    this.codecs,
  });

  final DashTrackKind kind;
  final String id;
  final Uri baseUri;
  final MpdSegmentInfo segment;
  final Duration? periodDuration;
  final int? bandwidth;
  final int? width;
  final int? height;
  final String? codecs;

  String get label {
    final int? w = width;
    final int? h = height;
    if (w != null && h != null) return '${h}p · ${bandwidth ?? 0} bps';
    return kind == DashTrackKind.video ? '视频轨' : '音频轨';
  }
}

class MpdSelectedTracks {
  const MpdSelectedTracks({this.video, this.audio});

  final MpdSelectedTrack? video;
  final MpdSelectedTrack? audio;

  bool get isEmpty => video == null && audio == null;
}
