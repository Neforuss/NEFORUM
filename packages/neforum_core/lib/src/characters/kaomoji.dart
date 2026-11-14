// The Kaomoji tab's set.
//
// Provenance: written for NEFORUM in 2026 from kaomoji in everyday use on
// Japanese and English-language forums and chats (a folk form from 2channel
// text culture, short and unowned). No list, site or app was copied, scraped
// or reordered: the selection, grouping, names and order are NEFORUM's own,
// under the project's GPL-3.0. textgenerator.net, alt-codes.net and
// copypastecharacter.com were looked at only as a checklist of kinds to offer.
//
// House rules for the set, held by test/characters/kaomoji_test.dart:
// - one line each, no leading or trailing space;
// - no ASCII # or @ (they start hashtags and mentions on most networks: use
//   the fullwidth ＃ and ＠);
// - each one survives every network's text path, Markdown networks included
//   (text/network_text_transforms.dart escapes what CommonMark would eat and
//   puts what MFM would read in <plain>).

/// One group of the Kaomoji tab.
typedef KaomojiGroup = ({String id, String title, List<String> keywords, List<String> kaomoji});

/// The curated set, by feeling and then by kind.
const List<KaomojiGroup> kKaomojiGroups = [
  (
    id: 'joy',
    title: 'Joy',
    keywords: ['happy', 'smile', 'glad', 'yay', 'excited'],
    kaomoji: [
      '(＾▽＾)', '(^_^)', '(^o^)', '(*^▽^*)', 'ヽ(・∀・)ﾉ', '(≧▽≦)', '(o^▽^o)', '٩(◕‿◕)۶', '(✿◠‿◠)', '＼(^o^)／', '(^ω^)', '(◠‿◠)',
      'ヽ(^。^)ノ', '(⌒▽⌒)', '(๑˃ᴗ˂)ﻭ', '(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧', '٩(^‿^)۶', '(≧◡≦)', '(´▽`)', '＼(≧▽≦)／', 'ヾ(＾∇＾)', '(o˘◡˘o)', '(^▽^)',
      '☆*:.｡.o(≧▽≦)o.｡.:*☆', '(*¯︶¯*)', 'ʘ‿ʘ', '(•‿•)', '(｡◕‿◕｡)', '(⌒‿⌒)', '(☆▽☆)', '(/^▽^)/', '٩(｡•́‿•̀｡)۶',
    ],
  ),
  (
    id: 'love',
    title: 'Love',
    keywords: ['heart', 'cute', 'kiss', 'crush', 'adore'],
    kaomoji: [
      '(♡°▽°♡)', '(´∀｀)♡', '(◍•ᴗ•◍)❤', '(ღ˘⌣˘ღ)', '♡(｡- ω -)', '(｡♥‿♥｡)', '(*♡∀♡)', '(´｡• ω •｡`) ♡', '(っ˘з(˘⌣˘ ) ♡',
      '(｡・//ε//・｡)', '( ˘ ³˘)♥', '♡＼(￣▽￣)／♡', '(灬º‿º灬)♡', '❤ (ɔˆз(ˆ⌣ˆc)', '(◕‿◕)♡', '(´ ε ` )♡', '(≧◡≦) ♡', '♡( ◡‿◡ )',
      '(*˘︶˘*).｡.:*♡', '(づ￣ ³￣)づ',
    ],
  ),
  (
    id: 'shy',
    title: 'Shy',
    keywords: ['blush', 'embarrassed', 'bashful', 'flustered'],
    kaomoji: [
      '(⁄ ⁄•⁄ω⁄•⁄ ⁄)', '(/ω＼)', '(〃▽〃)', '(///▽///)', '(*ﾉωﾉ)', '(⁄ ⁄>⁄ ▽ ⁄<⁄ ⁄)', '(„ಡωಡ„)', '(*^.^*)', '(〃＞＿＜;〃)',
      '(/▽＼)', '(*´∀｀*)', '(〃ω〃)', '(｡•ˇ‸ˇ•｡)', '(⌒_⌒;)',
    ],
  ),
  (
    id: 'sad',
    title: 'Sad',
    keywords: ['cry', 'tears', 'upset', 'unhappy', 'sorrow'],
    kaomoji: [
      '(╥﹏╥)', '(T_T)', '(ಥ﹏ಥ)', '(;﹏;)', '(｡•́︿•̀｡)', '(つ﹏⊂)', '(ノ_<。)', '(´；ω；`)', '｡ﾟ･ (>﹏<) ･ﾟ｡', '(ಥ_ಥ)', '(T▽T)',
      '(｡╯︵╰｡)', '(μ_μ)', 'o(TヘTo)', '(︶︹︺)', '(´°ω°`)', '(ノ﹏ヽ)', '(-_-。)', '(ㄒoㄒ)', '(´._.`)',
    ],
  ),
  (
    id: 'comfort',
    title: 'Comfort',
    keywords: ['sympathy', 'pat', 'there there', 'support', 'kind'],
    kaomoji: [
      '(ノ_<。)ヾ(´ ▽ ` )', 'ヽ(~_~(・_・ )ゝ', '(っ´ω`)ﾉ(╥ω╥)', 'ρ(- ω -、)ヾ(￣ω￣; )', '(つ≧▽≦)つ(╥﹏╥)', '(´-ω-)ﾉ(ᗒᗩᗕ)',
      '( ´ ∀ `)ノ～ ♡',
    ],
  ),
  (
    id: 'angry',
    title: 'Angry',
    keywords: ['mad', 'rage', 'annoyed', 'furious', 'grumpy'],
    kaomoji: [
      '(╬ Ò﹏Ó)', '(＃`Д´)', '(`皿´＃)', 'ヽ(`⌒´メ)ノ', '(ಠ_ಠ)', '(¬_¬)', '(≖_≖ )', 'ヽ(＃`Д´)ﾉ', '(｀ε´)', '(＃ﾟДﾟ)',
      '٩(╬ʘ益ʘ╬)۶', '(`Д´)', '(◣_◢)', '(ꐦ°᷄д°᷅)', '(・`ω´・)', '(｀へ´)', 'ლ(ಠ益ಠლ)', '(ﾒ` ﾛ ´)',
    ],
  ),
  (
    id: 'table',
    title: 'Table flip',
    keywords: ['flip', 'table', 'rage', 'unflip', 'calm'],
    kaomoji: [
      '(╯°□°）╯︵ ┻━┻', '┬─┬ノ( º _ ºノ)', '(ノಠ益ಠ)ノ彡┻━┻', '┻━┻ ︵ヽ(`Д´)ﾉ︵ ┻━┻', '(┛◉Д◉)┛彡┻━┻', '┬─┬ ノ( ゜-゜ノ)',
      '(╯°Д°）╯︵ /(.□ . \\)', '(ノ°▽°)ノ︵┻━┻', '┻━┻ミ＼(≧ﾛ≦＼)', '(╯ರ ~ ರ）╯︵ ┻━┻', '┬──┬◡ﾉ(° -°ﾉ)',
    ],
  ),
  (
    id: 'shrug',
    title: 'Shrug',
    keywords: ['whatever', 'meh', 'dunno', 'indifferent', 'idk'],
    kaomoji: [
      '¯\\_(ツ)_/¯', '┐(￣ヘ￣)┌', '╮(╯_╰)╭', '¯\\_(ಠ_ಠ)_/¯', '┐(︶▽︶)┌', 'ヽ(ー_ー )ノ', '┐( ˘_˘ )┌', '┐(‘～` )┌', '¯\\_(°_o)_/¯',
      '╮(￣ω￣;)╭', '(￣ー￣)', '┐(´ー`)┌', '¯\\_( ͡° ͜ʖ ͡°)_/¯',
    ],
  ),
  (
    id: 'surprise',
    title: 'Surprise',
    keywords: ['surprised', 'shock', 'wow', 'omg', 'amazed'],
    kaomoji: [
      '(⊙_⊙)', '(°ロ°)', 'Σ(°△°|||)︴', '(O_O)', '(ﾟДﾟ;)', 'w(°ｏ°)w', 'ヽ(°〇°)ﾉ', '(⊙０⊙)', 'Σ(O_O)', '(°o°)', '(o_O)',
      '(◎_◎;)', '(*ﾟﾛﾟ)', '(°ー°〃)', '(＠_＠)', 'Σ(ﾟロﾟ)',
    ],
  ),
  (
    id: 'confused',
    title: 'Confused',
    keywords: ['thinking', 'hmm', 'doubt', 'puzzled', 'question'],
    kaomoji: [
      '(・_・;)', '(⊙_☉)', '(￢_￢)', '(・・ ) ?', '(゜-゜)', '( ˘･з･)', '(・∧・)', "┐('～`;)┌", '(o_O)?', '(⊙.☉)7', '(・・;)ゞ',
      '(｀_´)ゞ', '( •᷄ὤ•᷅)？', '(¯ . ¯٥)', '(-_-;)・・・',
    ],
  ),
  (
    id: 'nervous',
    title: 'Nervous',
    keywords: ['worried', 'scared', 'fear', 'anxious', 'sweat'],
    kaomoji: [
      '(ﾟДﾟ;≡;ﾟДﾟ)', '(；￣Д￣)', '(ノωヽ)', '＼(〇_ｏ)／', '〜(＞＜)〜', '(;;;*_*)', 'ヽ(ﾟДﾟ)ﾉ', '(×_×;)', '(・_・ヾ', '(￣▽￣;)',
      '(^_^;)', '(⌒_⌒;)', '(°ㅂ°)', '((((；゜Д゜)))',
    ],
  ),
  (
    id: 'sleepy',
    title: 'Sleepy',
    keywords: ['tired', 'sleep', 'night', 'bored', 'zzz'],
    kaomoji: [
      '(－_－) zzZ', '(￣o￣) . z Z', '(-.-)Zzz', '(∪｡∪)｡｡｡zzZ', '( ˘ω˘ )ｽﾔｧ', '(=_=)', '(´-ω-`)', '(￣ρ￣)..zzZZ', '(¦3[▓▓]',
      '(ᴗ˳ᴗ)', '(－.－)…zzz',
    ],
  ),
  (
    id: 'wink',
    title: 'Wink and smug',
    keywords: ['wink', 'smug', 'cool', 'sly', 'flirt'],
    kaomoji: [
      '(^_~)', '(ゝ‿◕)', '(^_-)≡☆', '(¬‿¬)', '(￣ー￣)ｂ', '(￣▽￣)ノ', '☆⌒(ゝ。∂)', '(⌐■_■)', '( •_•)>⌐■-■', '(•̀ω•́)✧',
      '(￣︶￣)', '( ˘ ᵕ ˘ )', '(￢‿￢ )',
    ],
  ),
  (
    id: 'greeting',
    title: 'Hello and goodbye',
    keywords: ['hi', 'hello', 'wave', 'bye', 'greeting'],
    kaomoji: [
      '(^_^)/', '(￣▽￣)ノ', 'ヾ(・ω・)ノ', '(*・ω・)ﾉ', 'ヾ(＾∇＾)', '( ﾟ▽ﾟ)/', '(o´▽`o)ﾉ', 'ヾ(☆▽☆)', '(^-^*)/', '(=ﾟωﾟ)ﾉ',
      '(・∀・)ノ', '(*´ω｀)o', '(｡･∀･)ﾉ', 'ヾ(´･ω･｀)',
    ],
  ),
  (
    id: 'hug',
    title: 'Hugs',
    keywords: ['hug', 'cuddle', 'embrace', 'friends'],
    kaomoji: [
      '(っ´▽`)っ', '⊂(´・ω・｀⊂)', '(づ｡◕‿‿◕｡)づ', '༼ つ ◕_◕ ༽つ', '(つ≧▽≦)つ', '⊂(◉‿◉)つ', '(っ˘ω˘ς )', '(づ◡﹏◡)づ',
      '(⊃｡•́‿•̀｡)⊃', '(ﾉ´ з `)ノ', '(つ . •́ _ʖ •̀ .)つ', '(っ◔◡◔)っ ♥',
    ],
  ),
  (
    id: 'sorry',
    title: 'Sorry and thanks',
    keywords: ['sorry', 'apology', 'bow', 'thanks', 'please'],
    kaomoji: [
      'm(_ _)m', '(シ_ _)シ', '<(_ _)>', '(人´∀｀)', 'm(._.)m', '＿|￣|○', 'orz', 'OTL', '(._.)', '(シ. .)シ', '(人 •͈ᴗ•͈)',
      'ペコリ(o_ _)o',
    ],
  ),
  (
    id: 'dance',
    title: 'Dance and music',
    keywords: ['dance', 'music', 'party', 'sing', 'celebrate'],
    kaomoji: [
      'ヾ(⌐■_■)ノ♪', '♪┏(・o･)┛♪', '┌(・。・)┘♪', 'ヽ(⌐■_■)ノ♪♬', '♪～(￣ε￣)', '(〜￣▽￣)〜', '〜(￣▽￣〜)', '♬♩♪♩',
      '(ﾉ´ヮ`)ﾉ*: ･ﾟ', '└(＾＾)┐', '┌(＾＾)┘', '♪(┌・。・)┌', 'ヘ(￣ー￣ヘ)', '(ノ￣ー￣)ノ', '♪♫•*¨*•.¸¸♪',
    ],
  ),
  (
    id: 'strong',
    title: 'Strong and running',
    keywords: ['flex', 'strong', 'run', 'fight', 'go'],
    kaomoji: [
      'ᕦ(ò_óˇ)ᕤ', 'ᕙ(⇀‸↼‶)ᕗ', 'ᕕ( ᐛ )ᕗ', '(ง •̀_•́)ง', "(ง'̀-'́)ง", 'ε=ε=ε=┌(;*´Д`)ﾉ', '─=≡Σ((( つ•̀ω•́)つ', 'ε===(っ≧ω≦)っ',
      '┌( ಠ_ಠ)┘', '(ﾉ´ヮ`)ﾉ', '٩(ˊᗜˋ*)و', '(•̀ᴗ•́)و',
    ],
  ),
  (
    id: 'cat',
    title: 'Cats',
    keywords: ['cat', 'kitty', 'meow', 'neko'],
    kaomoji: [
      '(=^･ω･^=)', 'ฅ^•ﻌ•^ฅ', '(=①ω①=)', '(^・ω・^ )', '(=ↀωↀ=)', '(=^‥^=)', 'ฅ(＾・ω・＾ฅ)', '(=`ω´=)', '(=ＴェＴ=)',
      '(＾• ω •＾)', '(ↀДↀ)',
    ],
  ),
  (
    id: 'bear',
    title: 'Bears',
    keywords: ['bear', 'teddy'],
    kaomoji: ['ʕ•ᴥ•ʔ', 'ʕ ᵔᴥᵔ ʔ', 'ʕ •̀ ω •́ ʔ', 'ʕ￫ᴥ￩ʔ', 'ʕ ꈍᴥꈍʔ', 'ʕノ•ᴥ•ʔノ ︵ ┻━┻', 'ʕ ´•̥̥̥ ᴥ•̥̥̥`ʔ', 'ʕ　·ᴥ·ʔ'],
  ),
  (
    id: 'animals',
    title: 'Other animals',
    keywords: ['dog', 'rabbit', 'bunny', 'bird', 'fish', 'pig', 'spider', 'animal'],
    kaomoji: [
      '∪･ω･∪', 'U^ｪ^U', '▼・ᴥ・▼', '(◕ᴥ◕)', '(・x・)', '⊂(・x・)⊃', '(・θ・)', '( ˙▿˙ )', '<゜)))彡', '<º))))><', '(￣(00)￣)',
      '/╲/\\╭(ఠఠ益ఠఠ)╮/\\╱\\', '(°)>', 'ζ°)))彡', 'くコ:彡', '( ･ั﹏･ั)',
    ],
  ),
  (
    id: 'food',
    title: 'Food and drink',
    keywords: ['food', 'eat', 'drink', 'coffee', 'tea', 'yummy', 'hungry'],
    kaomoji: [
      '(っ˘ڡ˘ς)', '( ˘▽˘)っ♨', '( ・ω・)o-旦', '(*´ー`)旦', '(っ˘ω˘ς )🍰', '( ˘ ³˘)☕', '(￣～￣)', '(・ε・)🍙', '♨(⋆‿⋆)♨', '(°﹃°)',
    ],
  ),
  (
    id: 'magic',
    title: 'Magic and sparkles',
    keywords: ['magic', 'sparkle', 'wand', 'shine', 'stars'],
    kaomoji: [
      '(∩^o^)⊃━☆ﾟ.*･｡ﾟ', '(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧', '✧*｡٩(ˊᗜˋ*)و✧*｡', '(∩｀-´)⊃━☆ﾟ.*･｡ﾟ', '(ノ°∀°)ノ⌒･*:.｡. .｡.:*･゜ﾟ･*☆',
      '☆ﾟ.*･｡ﾟ', '(*^▽^)/★*☆♪', '✩°｡⋆⸜(ू｡•ω•｡)', '٩(◕‿◕｡)۶✧',
    ],
  ),
  (
    id: 'faces',
    title: 'Lenny and friends',
    keywords: ['lenny', 'meme', 'look', 'disapproval', 'point'],
    kaomoji: [
      '( ͡° ͜ʖ ͡°)', '( ͠° ͟ʖ ͡°)', '( ͡ᵔ ͜ʖ ͡ᵔ )',
      'ಠ_ಠ', 'ಠ‿ಠ', '( ಠ ͜ʖಠ)', '(☞ﾟヮﾟ)☞', '☜(ﾟヮﾟ☜)', '(•_•)', '(◉_◉)', '(¬‿¬ )', '༼ ºل͟º ༽', '(ʘ‿ʘ)', '(°ᴗ°)',
      '( ͡~ ͜ʖ ͡°)', 'ᕕ( ͡° ͜ʖ ͡°)ᕗ',
    ],
  ),
  (
    id: 'dividers',
    title: 'Dividers',
    keywords: ['divider', 'border', 'line', 'separator', 'decoration'],
    kaomoji: [
      '･ﾟ✧*:･ﾟ✧ ･ﾟ✧*:･ﾟ✧', '✦ ✦ ✦', '━━━━━━━━━━━━', '────── ⋆⋅☆⋅⋆ ──────', '•·.·´¯`·.·•', '═══════════', '✿ ✿ ✿ ✿',
      '⊱ ────── {.⋅ ✯ ⋅.} ────── ⊰', '▬▬▬▬▬▬▬▬▬', '～～～～～～', '.・。.・゜✭・.・✫・゜・。.', '┈┈┈┈┈┈┈┈┈', '◦•●◉✿ ✿◉●•◦',
      '⋆｡˚ ☁ ˚｡⋆｡˚☽˚｡⋆', '꒰ ꒱ ꒰ ꒱ ꒰ ꒱', '▓▒░ ░▒▓', '❀•°•═════ஓ๑♡๑ஓ═════•°•❀', '◇◆◇◆◇◆◇', '⋆ ˚｡⋆୨୧˚ ˚｡⋆',
    ],
  ),
];

/// One choice of the kaomoji builder: what goes on the left and on the right.
typedef KaomojiPart = ({String left, String right});

/// The builder's parts: a kaomoji is arms, a face's edge, eyes and a mouth,
/// read as `left arm, left edge, left eye, mouth, right eye, right edge,
/// right arm`. The user picks each; nothing is generated unseen.
abstract final class KaomojiBuilder {
  static const List<KaomojiPart> arms = [
    (left: '', right: ''),
    (left: 'ヽ', right: 'ﾉ'),
    (left: '٩', right: '۶'),
    (left: '╰', right: '╯'),
    (left: 'ᕕ', right: 'ᕗ'),
    (left: 'ᕦ', right: 'ᕤ'),
    (left: '⊂', right: '⊃'),
    (left: 'ლ', right: 'ლ'),
    (left: '┌', right: '┐'),
    (left: '＼', right: '／'),
    (left: '(ﾉ', right: ')ﾉ'),
    (left: 'o', right: 'o'),
  ];

  static const List<KaomojiPart> edges = [
    (left: '(', right: ')'),
    (left: '（', right: '）'),
    (left: 'ʕ', right: 'ʔ'),
    (left: '༼', right: '༽'),
    (left: '[', right: ']'),
    (left: '{', right: '}'),
    (left: '|', right: '|'),
    (left: '', right: ''),
  ];

  static const List<KaomojiPart> eyes = [
    (left: '^', right: '^'),
    (left: '•', right: '•'),
    (left: '◕', right: '◕'),
    (left: '°', right: '°'),
    (left: 'ಠ', right: 'ಠ'),
    (left: '>', right: '<'),
    (left: '≧', right: '≦'),
    (left: 'T', right: 'T'),
    (left: '◉', right: '◉'),
    (left: '¬', right: '¬'),
    (left: '☆', right: '☆'),
    (left: '♥', right: '♥'),
    (left: 'ʘ', right: 'ʘ'),
    (left: 'ᵔ', right: 'ᵔ'),
    (left: '⊙', right: '⊙'),
    (left: 'ò', right: 'ó'),
    (left: '˘', right: '˘'),
    (left: '-', right: '-'),
    (left: 'ᗒ', right: 'ᗕ'),
    (left: '×', right: '×'),
  ];

  static const List<String> mouths = ['‿', 'ᴥ', 'ω', '▽', '∀', 'ヮ', '_', '﹏', '□', 'Д', '益', 'ε', '.', 'o', '◡', 'ᗜ', '︿', 'ㅅ', '‸', '⌓'];

  /// The kaomoji made of [arm], [edge], [eye] and [mouth].
  static String build({required KaomojiPart arm, required KaomojiPart edge, required KaomojiPart eye, required String mouth}) =>
      '${arm.left}${edge.left}${eye.left}$mouth${eye.right}${edge.right}${arm.right}';
}

/// Every kaomoji of [kKaomojiGroups], once each, in order.
List<String> get allKaomoji {
  final seen = <String>{};
  return [
    for (final g in kKaomojiGroups)
      for (final k in g.kaomoji)
        if (seen.add(k)) k,
  ];
}
