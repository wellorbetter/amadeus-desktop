import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/reply_content.dart';

/// U4 自检（内容解析部分）：Spec §7.3 的 `display_text / speech_text /
/// completion_status` 三元组、标记剥离与「不朗读未审核结果」。
void main() {
  ReplyContent parse(
    String raw, {
    CompletionStatus status = CompletionStatus.complete,
    String detail = 'stop',
  }) => ReplyContent.parse(raw, status: status, detail: detail);

  group('标记剥离', () {
    test('行首 [HH:MM] 是气泡装饰，剥离后不进字幕也不进语音', () {
      final r = parse('[23:41] 你又熬夜了？');

      expect(r.bubbleTime, '23:41');
      expect(r.displayText, '你又熬夜了？');
      expect(r.speechText, '你又熬夜了？');
    });

    test('句子中间的真实时间不被删除', () {
      // Spec §7.3：正常正文中的真实时间不得被一条全局正则无差别删掉。
      final r = parse('我们说好 [14:30] 见面，你忘了吧。');

      expect(r.bubbleTime, isNull);
      expect(r.displayText, contains('[14:30]'));
      expect(r.speechText, contains('[14:30]'));
    });

    test('不合法的时间不当作气泡标记', () {
      final r = parse('[99:99] 这不是时间');
      expect(r.bubbleTime, isNull);
      expect(r.displayText, contains('[99:99]'));
    });

    test('白名单内的表情被提取，白名单外的被丢弃并留下说明', () {
      final ok = parse('好啦好啦[[sticker:tap_body]]别催了');
      expect(ok.stickers, ['tap_body']);
      expect(ok.displayText, '好啦好啦别催了');
      expect(ok.speechText, '好啦好啦别催了');

      final bad = parse('哼[[sticker:../../etc/passwd]]');
      expect(bad.stickers, isEmpty, reason: '白名单外的引用不下传');
      expect(bad.displayText, '哼');
      expect(bad.unspokenNotes.join(), contains('白名单'));
    });

    test('表情引用不会把脚本片段带进动作名', () {
      // motion() 把名字直接拼进 window.pet.motion("$name") 执行。
      final r = parse('[[sticker:x");alert(1);//]]嗯');
      expect(r.stickers, isEmpty);
      expect(r.displayText, '嗯');
    });

    test('其它元数据标记被忽略但会记录', () {
      final r = parse('[[audio:C:/tmp/a.wav]]我说完了');
      expect(r.displayText, '我说完了');
      expect(r.unspokenNotes.join(), contains('元数据标记'));
    });
  });

  group('推理内容不是答案', () {
    test('闭合的思考区块被剥掉', () {
      final r = parse('<think>用户在试探我</think>怎么了？');
      expect(r.displayText, '怎么了？');
      expect(r.speechText, '怎么了？');
    });

    test('未闭合的思考区块之后的内容一律不显示不朗读', () {
      final r = parse('哦？<think>他好像在问');
      expect(r.displayText, '哦？');
      expect(r.speechText, '哦？');
      expect(r.unspokenNotes.join(), contains('未闭合'));
    });

    test('整段都是推理时判为 empty，不是 complete', () {
      final r = parse('<think>还在想</think>');
      expect(r.status, CompletionStatus.empty);
      expect(r.speakable, isFalse);
      expect(r.detail, 'empty_after_parse');
    });
  });

  group('异常状态下关闭语音', () {
    test('截断的正文可以显示，但绝不朗读', () {
      final r = parse(
        '这个实验的关键在于',
        status: CompletionStatus.truncated,
        detail: 'length',
      );

      expect(r.hasDisplayText, isTrue);
      expect(r.displayText, '这个实验的关键在于');
      expect(r.speechText, isEmpty);
      expect(r.speakable, isFalse);
      expect(r.detail, 'length', reason: '沿用底层判定原因，不改写');
    });

    test('malformed 不朗读未审核的原始结果', () {
      final r = parse(
        'half',
        status: CompletionStatus.malformed,
        detail: 'malformed_event',
      );
      expect(r.speechText, isEmpty);
      expect(r.speakable, isFalse);
      expect(r.unspokenNotes.join(), contains('malformed'));
    });

    test('已取消的轮次不朗读', () {
      final r = parse(
        '刚才那句',
        status: CompletionStatus.cancelled,
        detail: 'cancelled',
      );
      expect(r.speakable, isFalse);
      expect(r.speechText, isEmpty);
    });

    test('空正文不能声称完整', () {
      expect(parse('   ').status, CompletionStatus.empty);
      expect(parse('').speakable, isFalse);
    });
  });

  group('长内容保留为文字并标注未朗读', () {
    test('代码块进字幕不进语音', () {
      final r = parse('喏，这样写：\n```dart\nvoid main() {}\n```\n看懂了吗？');

      expect(r.displayText, contains('void main()'));
      expect(r.speechText, isNot(contains('void main()')));
      expect(r.speechText, contains('看懂了吗'));
      expect(r.unspokenNotes.join(), contains('代码块'));
    });

    test('未闭合的代码块同样不朗读', () {
      final r = parse('看这段：\n```dart\nvoid main() {');
      expect(r.speechText, isNot(contains('void main')));
      expect(r.unspokenNotes.join(), contains('代码块'));
    });

    test('链接进字幕不进语音', () {
      final r = parse('资料在 https://example.com/a/b?c=1 里，自己看。');

      expect(r.displayText, contains('https://example.com/a/b?c=1'));
      expect(r.speechText, isNot(contains('example.com')));
      expect(r.speechText, contains('自己看'));
      expect(r.unspokenNotes.join(), contains('链接'));
    });

    test('字幕与语音在普通文本上完全一致', () {
      final r = parse('少熬夜，明天还要做实验。');
      expect(r.speechText, r.displayText);
      expect(r.unspokenNotes, isEmpty);
    });
  });

  group('流式预览处理跨 token 的半个标记', () {
    test('尾部不完整的表情标记先藏起来', () {
      expect(ReplyContent.previewOf('好啦[[stick'), '好啦');
      expect(ReplyContent.previewOf('好啦[[sticker:tap'), '好啦');
      expect(
        ReplyContent.previewOf('好啦[[sticker:tap_body]]别催'),
        '好啦别催',
      );
    });

    test('尾部不完整的时间标记先藏起来', () {
      expect(ReplyContent.previewOf('[2'), '');
      expect(ReplyContent.previewOf('[23:'), '');
      expect(ReplyContent.previewOf('[23:4'), '');
      expect(ReplyContent.previewOf('[23:41] 你'), '你');
    });

    test('尾部不完整的标签先藏起来', () {
      expect(ReplyContent.previewOf('嗯<thin'), '嗯');
      expect(ReplyContent.previewOf('嗯<think>在想'), '嗯');
      expect(ReplyContent.previewOf('嗯<think>在想</think>好了'), '嗯好了');
    });

    test('逐字累积的过程中不会闪出半个标记', () {
      const full = '[23:41] 熬夜了？[[sticker:shake]]睡吧。';
      final seen = <String>[];
      for (var i = 1; i <= full.length; i++) {
        seen.add(ReplyContent.previewOf(full.substring(0, i)));
      }

      for (final frame in seen) {
        expect(frame, isNot(contains('[[')));
        expect(frame, isNot(contains('sticker')));
        expect(frame, isNot(contains(']]')));
        expect(frame, isNot(matches(RegExp(r'\[\d'))));
      }
      expect(seen.last, '熬夜了？睡吧。');
    });
  });
}
