/// 一次回复的完成情况（Spec §7.3 的 `completion_status`）。
///
/// 只有 [complete] 允许朗读。其余状态都表示「这段文字没有经过完整校验」，
/// 此时必须关闭语音并显示系统状态，不能把不完整正文冒充完整回复。
enum CompletionStatus {
  /// 完整合法的角色正文。
  complete,

  /// 请求成功，但剥掉推理与标记后没有正文。
  empty,

  /// 输出被截断（`finish_reason == length`）。
  truncated,

  /// SSE 事件损坏、供应商返回 error、格式异常。
  malformed,

  /// 本轮已被取消或抢占。
  cancelled,

  /// 网络或 HTTP 层失败。
  transportFailed,
}

/// 供应商结果经模型适配层转换后的三元组（Spec §7.3）。
///
/// [displayText] 给用户看，[speechText] 给 TTS，[status] 说明这段文字算不算数。
/// 三者必须分开：字幕可以保留一段被截断的文字并标注未完成，语音不行。
class ReplyContent {
  const ReplyContent({
    required this.displayText,
    required this.speechText,
    required this.status,
    required this.detail,
    this.bubbleTime,
    this.stickers = const [],
    this.unspokenNotes = const [],
  });

  /// 用户可见正文。保留真实时间、代码块、链接等内容，只剥掉元数据标记与推理。
  final String displayText;

  /// 交给 TTS 的文本。不含任何标记；代码块与链接已移除（见 [unspokenNotes]）。
  /// 非 [CompletionStatus.complete] 时**恒为空**。
  final String speechText;

  final CompletionStatus status;

  /// 状态细节，沿用底层的原始判定原因（`stop` / `length` / `malformed_event` …）。
  final String detail;

  /// `[HH:MM]` 气泡标记的解析结果。
  ///
  /// 这**不是**真实时间，只是模型按格式生成的气泡装饰，不得当作时间源使用。
  final String? bubbleTime;

  /// 白名单内的表情引用。白名单外的一律丢弃，不下传。
  final List<String> stickers;

  /// 哪些部分没有朗读，以及为什么。UI 须显式告知用户，
  /// 不能悄悄少讲一段（Spec §7.3）。
  final List<String> unspokenNotes;

  /// 是否允许朗读。
  bool get speakable =>
      status == CompletionStatus.complete && speechText.trim().isNotEmpty;

  /// 是否有可显示给用户的文字（截断的半句话也算，会另附状态）。
  bool get hasDisplayText => displayText.trim().isNotEmpty;

  static const ReplyContent none = ReplyContent(
    displayText: '',
    speechText: '',
    status: CompletionStatus.empty,
    detail: 'none',
  );

  /// 预定义的表情白名单。
  ///
  /// 来自 `KurisuController.motion` 已支持的动作名。必须是白名单而非放行任意
  /// 字符串：那个方法把名字直接拼进 `window.pet.motion("$name")` 执行，
  /// 模型生成的内容一旦直通就是脚本注入面。
  static const Set<String> defaultStickerWhitelist = {
    'tap_body',
    'flick_head',
    'shake',
    'pinch_in',
    'pinch_out',
  };

  /// 闭合的思考区块。只消费用户可见答案，独立的 reasoning 内容一律忽略。
  static final RegExp _closedThink = RegExp(
    r'<(think|thinking|reasoning)>[\s\S]*?</\1>',
    caseSensitive: false,
  );

  /// 未闭合的思考区块：从开标签一直到结尾都算推理，不能当正文显示。
  static final RegExp _openThink = RegExp(
    r'<(think|thinking|reasoning)>[\s\S]*$',
    caseSensitive: false,
  );

  /// `[[key:value]]` 形式的元数据标记。
  static final RegExp _metaMarker = RegExp(
    r'\[\[([A-Za-z_][\w-]*)\s*:\s*([^\]\n]{0,64})\]\]',
  );

  /// 行首的 `[HH:MM]` 气泡标记。
  ///
  /// 刻意只匹配行首：句子中间的 `[14:30]` 是用户真实引用的时间，
  /// 不能被一条全局正则无差别删除（Spec §7.3）。
  static final RegExp _bubbleTimeMarker = RegExp(
    r'^[ \t]*\[([01]\d|2[0-3]):([0-5]\d)\][ \t]*',
    multiLine: true,
  );

  /// 围栏代码块，含未闭合的那种。
  static final RegExp _fencedCode = RegExp(r'```[\s\S]*?(?:```|$)');

  static final RegExp _url = RegExp(
    r'(?:https?://|www\.)\S+',
    caseSensitive: false,
  );

  /// 把供应商的原始正文转成三元组。
  ///
  /// [status] 由传输层给出（是否看到 `[DONE]`、`finish_reason` 是什么、
  /// 有没有坏事件）。本方法不会把一个失败状态改判成成功，只会在正文实际为空时
  /// 把 [CompletionStatus.complete] 降为 [CompletionStatus.empty]。
  factory ReplyContent.parse(
    String raw, {
    CompletionStatus status = CompletionStatus.complete,
    String detail = 'stop',
    Set<String> stickerWhitelist = defaultStickerWhitelist,
  }) {
    final notes = <String>[];
    final stickers = <String>[];
    String? bubbleTime;

    var text = raw;

    // 1. 推理内容不是答案。闭合的先删，剩下的开标签之后全部算推理。
    final hadClosedThink = _closedThink.hasMatch(text);
    text = text.replaceAll(_closedThink, '');
    if (_openThink.hasMatch(text)) {
      text = text.replaceAll(_openThink, '');
      notes.add('思考区块未闭合，该部分未显示也未朗读');
    } else if (hadClosedThink) {
      notes.add('推理内容未显示也未朗读');
    }

    // 2. 元数据标记。sticker 过白名单，其余种类记录后丢弃。
    text = text.replaceAllMapped(_metaMarker, (m) {
      final key = m.group(1)!.toLowerCase();
      final value = (m.group(2) ?? '').trim();
      if (key == 'sticker') {
        if (stickerWhitelist.contains(value)) {
          stickers.add(value);
        } else {
          notes.add('表情 $value 不在白名单内，已忽略');
        }
      } else {
        notes.add('元数据标记 $key 已忽略');
      }
      return '';
    });

    // 3. 行首的气泡时间标记。取第一个作为气泡装饰，全部从正文剥离。
    text = text.replaceAllMapped(_bubbleTimeMarker, (m) {
      bubbleTime ??= '${m.group(1)}:${m.group(2)}';
      return '';
    });

    final display = _tidy(text);

    var finalStatus = status;
    var finalDetail = detail;
    if (finalStatus == CompletionStatus.complete && display.isEmpty) {
      finalStatus = CompletionStatus.empty;
      finalDetail = 'empty_after_parse';
    }

    // 4. 语音只在完整正文上生成。异常状态一律不朗读原始结果。
    if (finalStatus != CompletionStatus.complete) {
      notes.add('状态为 ${finalStatus.name}，未朗读');
      return ReplyContent(
        displayText: display,
        speechText: '',
        status: finalStatus,
        detail: finalDetail,
        bubbleTime: bubbleTime,
        stickers: List.unmodifiable(stickers),
        unspokenNotes: List.unmodifiable(notes),
      );
    }

    var speech = display;
    if (_fencedCode.hasMatch(speech)) {
      speech = speech.replaceAll(_fencedCode, ' ');
      notes.add('代码块保留为文字，该部分未朗读');
    }
    if (_url.hasMatch(speech)) {
      speech = speech.replaceAll(_url, ' ');
      notes.add('链接保留为文字，该部分未朗读');
    }

    return ReplyContent(
      displayText: display,
      speechText: _tidy(speech),
      status: finalStatus,
      detail: finalDetail,
      bubbleTime: bubbleTime,
      stickers: List.unmodifiable(stickers),
      unspokenNotes: List.unmodifiable(notes),
    );
  }

  /// 流式显示用的即时预览。
  ///
  /// 与 [parse] 的区别是它必须处理**跨 token 的半个标记**：累积文本可能正好停在
  /// `[[stick` 或 `[14:` 上，直接显示会让用户看到一闪而过的乱码。
  /// 尾部不完整的标记一律先藏起来，等后续 token 补全。
  static String previewOf(String partial) {
    var text = partial.replaceAll(_closedThink, '');
    // 未闭合的思考区块：正在生成推理，正文还没开始。
    text = text.replaceAll(_openThink, '');
    text = text.replaceAll(_metaMarker, '');
    text = text.replaceAllMapped(_bubbleTimeMarker, (_) => '');

    // 尾部半个 `[[...]]`。
    final lastOpen = text.lastIndexOf('[[');
    if (lastOpen >= 0 && !text.substring(lastOpen).contains(']]')) {
      text = text.substring(0, lastOpen);
    }
    // 尾部半个 `<think`。
    final lastTag = text.lastIndexOf('<');
    if (lastTag >= 0 && !text.substring(lastTag).contains('>')) {
      text = text.substring(0, lastTag);
    }
    // 尾部半个行首时间标记，如 `[1` / `[14:` / `[14:3`。
    final lastBreak = text.lastIndexOf('\n');
    final tail = text.substring(lastBreak + 1);
    final trimmedTail = tail.trimLeft();
    if (RegExp(r'^\[\d{0,2}:?\d{0,2}$').hasMatch(trimmedTail)) {
      text = text.substring(0, text.length - tail.length);
    } else if (text.endsWith('[')) {
      text = text.substring(0, text.length - 1);
    }
    return text.trimLeft();
  }

  /// 收拾空白：标记被剥掉后常留下多余空行与行尾空格。
  static String _tidy(String value) => value
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .trim();

  @override
  String toString() =>
      'ReplyContent(${status.name}/$detail display=${displayText.length}字 '
      'speech=${speechText.length}字'
      '${bubbleTime == null ? '' : ' time=$bubbleTime'}'
      '${stickers.isEmpty ? '' : ' stickers=$stickers'})';
}
