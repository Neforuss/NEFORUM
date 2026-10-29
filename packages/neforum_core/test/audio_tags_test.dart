import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoder;
import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

import 'support/audio_vectors.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

/// Every field, the way Mp3tag fills them in.
const _full = AudioTags(
  title: 'Señorita Ø',
  artist: 'Zoë & the Ünits',
  album: 'Ålbum — Deluxe',
  albumArtist: 'Various Artists',
  year: 2024,
  date: '2024-05-17',
  genre: 'Pop',
  trackNumber: 3,
  trackTotal: 12,
  discNumber: 1,
  composer: 'J. Doe',
  comment: 'Recorded live',
  lyrics: 'La la la\nLa la',
);

void _expectFull(AudioTags t, {bool date = true, bool trackTotal = true, bool lyrics = true}) {
  expect(t.title, _full.title);
  expect(t.artist, _full.artist);
  expect(t.album, _full.album);
  expect(t.albumArtist, _full.albumArtist);
  expect(t.year, 2024);
  if (date) expect(t.date, '2024-05-17');
  expect(t.genre, 'Pop');
  expect(t.trackNumber, 3);
  if (trackTotal) expect(t.trackTotal, 12);
  expect(t.discNumber, 1);
  expect(t.composer, _full.composer);
  expect(t.comment, _full.comment);
  if (lyrics) expect(t.lyrics, _full.lyrics);
}

List<Id3FrameSpec> _v23Frames(Id3Encoding e, Uint8List cover, {Uint8List? backCover, bool itunes = true}) => [
      ('TIT2', id3TextContent(e, [_full.title!])),
      ('TPE1', id3TextContent(e, [_full.artist!])),
      ('TALB', id3TextContent(e, [_full.album!])),
      ('TPE2', id3TextContent(e, [_full.albumArtist!])),
      ('TYER', id3TextContent(e, ['2024'])),
      ('TDAT', id3TextContent(e, ['1705'])),
      ('TCON', id3TextContent(e, ['(13)'])),
      ('TRCK', id3TextContent(e, ['3/12'])),
      ('TPOS', id3TextContent(e, ['1/2'])),
      ('TCOM', id3TextContent(e, [_full.composer!])),
      if (itunes) ('COMM', id3DescribedContent(e, ' 00000A2B 00000A2B', description: 'iTunNORM')),
      ('COMM', id3DescribedContent(e, _full.comment!)),
      ('USLT', id3DescribedContent(e, _full.lyrics!)),
      if (backCover != null) ('APIC', id3PictureContent(backCover, type: 4)),
      ('APIC', id3PictureContent(cover, description: 'Front', e: e)),
    ];

void main() {
  final jpeg = solidPicture();
  final png = solidPicture(png: true, r: 20, g: 200, b: 60);
  final back = solidPicture(r: 0, g: 0, b: 255);

  group('ID3v2', () {
    test('2.3 in UTF-16 with BOM: every frame, the front cover over a back cover', () {
      final file = _b([...id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg, backCover: back)), ...mp3Frames(4)]);
      final r = readAudioTags(file);
      _expectFull(r.tags);
      expect(r.cover, jpeg);
      expect(r.coverMimeType, 'image/jpeg');
    });

    test('2.4 in UTF-8: TDRC timestamp, several values, numeric genre', () {
      final e = Id3Encoding.utf8;
      final file = _b([
        ...id3v2(4, [
          ('TIT2', id3TextContent(e, [_full.title!])),
          ('TPE1', id3TextContent(e, ['Zoë', 'the Ünits'])),
          ('TDRC', id3TextContent(e, ['2024-05-17T08:00:00'])),
          ('TCON', id3TextContent(e, ['13'])),
          ('TRCK', id3TextContent(e, ['07'])),
          ('APIC', id3PictureContent(png, mime: 'image/png')),
        ], padding: 256),
        ...mp3Frames(2),
      ]);
      final r = readAudioTags(file);
      expect(r.tags.title, _full.title);
      expect(r.tags.artist, 'Zoë; the Ünits');
      expect(r.tags.year, 2024);
      expect(r.tags.date, '2024-05-17');
      expect(r.tags.genre, 'Pop');
      expect(r.tags.trackNumber, 7);
      expect(r.tags.trackTotal, isNull);
      expect(r.cover, png);
      expect(r.coverMimeType, 'image/png');
    });

    test('2.4 with every frame unsynchronised and an extended header', () {
      final frames = _v23Frames(Id3Encoding.utf8, jpeg)
          .map((f) => f.$1 == 'TYER' ? ('TDRC', id3TextContent(Id3Encoding.utf8, ['2024-05-17'])) : f)
          .where((f) => f.$1 != 'TDAT')
          .toList();
      final tag = id3v2(4, frames, unsync: true, extendedHeader: true);
      // The JPEG's FF D8 FF E0... really is unsynchronised.
      expect(tag.length, greaterThan(id3v2(4, frames, extendedHeader: true).length));
      final r = readAudioTags(_b([...tag, ...mp3Frames(2)]));
      _expectFull(r.tags);
      expect(r.cover, jpeg);
    });

    test('2.3 with the whole tag unsynchronised and an extended header', () {
      final tag = id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg), unsync: true, extendedHeader: true);
      final r = readAudioTags(_b([...tag, ...mp3Frames(2)]));
      _expectFull(r.tags);
      expect(r.cover, jpeg);
    });

    test('2.4 written with plain sizes (older iTunes)', () {
      final long = 'x' * 300; // a size whose syncsafe and plain readings differ
      final file = _b([
        ...id3v2(4, [
          ('COMM', id3DescribedContent(Id3Encoding.latin1, long)),
          ('TIT2', id3TextContent(Id3Encoding.latin1, ['After'])),
        ], plainSizesIn24: true),
        ...mp3Frames(2),
      ]);
      final r = readAudioTags(file);
      expect(r.tags.comment, long);
      expect(r.tags.title, 'After');
    });

    test('2.4 in UTF-16BE and ISO-8859-1', () {
      final file = _b([
        ...id3v2(4, [
          ('TIT2', id3TextContent(Id3Encoding.utf16be, ['日本語のタイトル'])),
          ('TPE1', id3TextContent(Id3Encoding.latin1, ['Beyoncé'])),
          ('USLT', id3DescribedContent(Id3Encoding.utf16be, 'Ligne un', description: 'desc', language: 'fra')),
        ]),
        ...mp3Frames(1),
      ]);
      final r = readAudioTags(file);
      expect(r.tags.title, '日本語のタイトル');
      expect(r.tags.artist, 'Beyoncé');
      expect(r.tags.lyrics, 'Ligne un');
    });

    test('2.3 frames compressed with zlib', () {
      final content = id3TextContent(Id3Encoding.latin1, ['Squeezed title']);
      final packed = ZLibEncoder().encodeBytes(content);
      // Compression flag (0x80) with the decompressed size in front.
      final frame = [...ascii('TIT2'), ...u32be(packed.length + 4), 0, 0x80, ...u32be(content.length), ...packed];
      final tag = [...ascii('ID3'), 3, 0, 0, ...syncsafe(frame.length), ...frame];
      expect(readAudioTags(_b([...tag, ...mp3Frames(1)])).tags.title, 'Squeezed title');
    });

    test('compressed frames that would inflate past 16 MB are skipped', () {
      List<int> tag(int major, List<int> frame) => [...ascii('ID3'), major, 0, 0, ...syncsafe(frame.length), ...frame];
      final kept = id3TextContent(Id3Encoding.latin1, ['Kept']);
      // The same size bytes in 2.3 and 2.4: under 128.
      final title = [...ascii('TIT2'), ...u32be(kept.length), 0, 0, ...kept];
      final content = id3TextContent(Id3Encoding.latin1, ['Squeezed title']);
      final packed = ZLibEncoder().encodeBytes(content);
      // 2.3, declaring 17 MB: not inflated at all.
      final declared = [...ascii('TCOM'), ...u32be(packed.length + 4), 0, 0x80, ...u32be(17 << 20), ...packed];
      var r = readAudioTags(_b([...tag(3, [...declared, ...title]), ...mp3Frames(1)]));
      expect(r.tags.composer, isNull);
      expect(r.tags.title, 'Kept', reason: 'the frames after it are read');
      // 2.4, its data length indicator declaring 17 MB.
      final indicated = [...ascii('TCOM'), ...syncsafe(packed.length + 4), 0, 0x09, ...syncsafe(17 << 20), ...packed];
      r = readAudioTags(_b([...tag(4, [...indicated, ...title]), ...mp3Frames(1)]));
      expect(r.tags.composer, isNull);
      expect(r.tags.title, 'Kept');
      // 2.3, declaring a small size but inflating to 17 MB: the inflater stops.
      final bomb = ZLibEncoder().encodeBytes([0, ...ascii('Bomb'), ...List.filled(17 << 20, 0x41)]);
      final lying = [...ascii('TCOM'), ...u32be(bomb.length + 4), 0, 0x80, ...u32be(64), ...bomb];
      r = readAudioTags(_b([...tag(3, [...lying, ...title]), ...mp3Frames(1)]));
      expect(r.tags.composer, isNull);
      expect(r.tags.title, 'Kept');
    });

    test('2.2 three-letter frames and PIC', () {
      final e = Id3Encoding.latin1;
      final file = _b([
        ...id3v2(2, [
          ('TT2', id3TextContent(e, ['Old'])),
          ('TP1', id3TextContent(e, ['Artist 22'])),
          ('TAL', id3TextContent(e, ['Album 22'])),
          ('TP2', id3TextContent(e, ['Band 22'])),
          ('TYE', id3TextContent(e, ['1999'])),
          ('TCO', id3TextContent(e, ['(17)Rock & Roll'])),
          ('TRK', id3TextContent(e, ['5/9'])),
          ('TPA', id3TextContent(e, ['2'])),
          ('TCM', id3TextContent(e, ['Writer'])),
          ('COM', id3DescribedContent(e, 'Old comment')),
          ('ULT', id3DescribedContent(e, 'Old words')),
          ('PIC', id3v22PictureContent(jpeg)),
        ]),
        ...mp3Frames(1),
      ]);
      final r = readAudioTags(file);
      expect(r.tags, const AudioTags(
        title: 'Old',
        artist: 'Artist 22',
        album: 'Album 22',
        albumArtist: 'Band 22',
        year: 1999,
        genre: 'Rock & Roll',
        trackNumber: 5,
        trackTotal: 9,
        discNumber: 2,
        composer: 'Writer',
        comment: 'Old comment',
        lyrics: 'Old words',
      ));
      expect(r.cover, jpeg);
    });

    test('genre references', () {
      String? genre(String value, {int major = 3}) => readAudioTags(_b([
            ...id3v2(major, [('TCON', id3TextContent(Id3Encoding.latin1, value.split('|')))]),
            ...mp3Frames(1),
          ])).tags.genre;
      expect(genre('(13)'), 'Pop');
      expect(genre('(17)(13)'), 'Rock; Pop');
      expect(genre('(RX)'), 'Remix');
      expect(genre('(CR)'), 'Cover');
      expect(genre('((Parenthesised)'), '(Parenthesised)');
      expect(genre('Synthwave'), 'Synthwave');
      expect(genre('13|Synthwave', major: 4), 'Pop; Synthwave');
      expect(genre('(255)'), isNull);
    });

    test('ID3v1 alone, and as a fallback for what ID3v2 lacks', () {
      final v1 = id3v1(title: 'V1 title', artist: 'V1 artist', album: 'V1 album', year: '1987', comment: 'V1 note', track: 4, genre: 17);
      final only = readAudioTags(_b([...mp3Frames(2), ...v1]));
      expect(only.tags, const AudioTags(
          title: 'V1 title', artist: 'V1 artist', album: 'V1 album', year: 1987, comment: 'V1 note', trackNumber: 4, genre: 'Rock'));
      final both = readAudioTags(_b([
        ...id3v2(3, [('TIT2', id3TextContent(Id3Encoding.latin1, ['V2 title']))]),
        ...mp3Frames(2),
        ...v1,
      ]));
      expect(both.tags.title, 'V2 title');
      expect(both.tags.artist, 'V1 artist');
      expect(both.tags.genre, 'Rock');
    });

    test('a file without tags reads as none', () {
      final r = readAudioTags(_b(mp3Frames(3)));
      expect(r.isEmpty, isTrue);
      expect(readAudioTags(Uint8List(0)).isEmpty, isTrue);
    });
  });

  group('Vorbis comments', () {
    final comments = [
      'TITLE=${_full.title}',
      'ARTIST=${_full.artist}',
      'ALBUM=${_full.album}',
      'ALBUMARTIST=${_full.albumArtist}',
      'DATE=2024-05-17',
      'GENRE=Pop',
      'TRACKNUMBER=3',
      'TRACKTOTAL=12',
      'DISCNUMBER=1/2',
      'COMPOSER=${_full.composer}',
      'COMMENT=${_full.comment}',
      'LYRICS=${_full.lyrics}',
    ];

    test('FLAC comments and PICTURE block', () {
      final r = readAudioTags(_b(flacFile(comments: comments, picture: jpeg)));
      _expectFull(r.tags);
      expect(r.cover, jpeg);
    });

    test('FLAC with an ID3 tag in front: the comments win', () {
      final r = readAudioTags(_b(flacFile(
        comments: ['TITLE=From comments'],
        before: id3v2(3, [
          ('TIT2', id3TextContent(Id3Encoding.latin1, ['From ID3'])),
          ('TPE1', id3TextContent(Id3Encoding.latin1, ['ID3 artist'])),
        ]),
      )));
      expect(r.tags.title, 'From comments');
      expect(r.tags.artist, 'ID3 artist');
    });

    test('lower-case keys, several artists, track "3/12"', () {
      final r = readAudioTags(_b(flacFile(comments: ['title=Low', 'artist=A', 'Artist=B', 'tracknumber=3/12', 'year=2001'])));
      expect(r.tags.title, 'Low');
      expect(r.tags.artist, 'A; B');
      expect(r.tags.trackNumber, 3);
      expect(r.tags.trackTotal, 12);
      expect(r.tags.year, 2001);
      expect(r.tags.date, isNull);
    });

    test('Ogg Opus with a base64 METADATA_BLOCK_PICTURE', () {
      final block = base64.encode(flacPicture(png, mime: 'image/png'));
      final r = readAudioTags(_b(oggOpus([...comments, 'METADATA_BLOCK_PICTURE=$block'])));
      _expectFull(r.tags);
      expect(r.cover, png);
      expect(r.coverMimeType, 'image/png');
    });

    test('Ogg Vorbis whose comment packet spans many pages', () {
      // A big picture makes the comment packet run over several pages.
      final big = noisePicture(width: 200, height: 200);
      expect(big.length, greaterThan(255 * 255 ~/ 4));
      final block = base64.encode(flacPicture(big, mime: 'image/png'));
      final r = readAudioTags(_b(oggVorbis([...comments, 'METADATA_BLOCK_PICTURE=$block'])));
      _expectFull(r.tags);
      expect(r.cover, big);
    });

    test('the old COVERART field', () {
      final r = readAudioTags(_b(oggVorbis(['TITLE=Old art', 'COVERART=${base64.encode(jpeg)}', 'COVERARTMIME=image/jpeg'])));
      expect(r.cover, jpeg);
    });
  });

  group('MP4', () {
    List<int> items(Uint8List cover) => [
          ...mp4Text('©nam', _full.title!),
          ...mp4Text('©ART', _full.artist!),
          ...mp4Text('©alb', _full.album!),
          ...mp4Text('aART', _full.albumArtist!),
          ...mp4Text('©day', '2024-05-17T07:00:00Z'),
          ...mp4Text('©gen', 'Pop'),
          ...mp4Item('trkn', 0, [0, 0, 0, 3, 0, 12, 0, 0]),
          ...mp4Item('disk', 0, [0, 0, 0, 1, 0, 2]),
          ...mp4Text('©wrt', _full.composer!),
          ...mp4Text('©cmt', _full.comment!),
          ...mp4Text('©lyr', _full.lyrics!),
          ...mp4Item('covr', 14, cover),
        ];

    test('moov/udta/meta/ilst with every item and covr', () {
      for (final moovFirst in [true, false]) {
        final r = readAudioTags(_b(m4aFile(moovFirst: moovFirst, udta: mp4Udta([items(png)]))));
        _expectFull(r.tags);
        expect(r.cover, png);
        expect(r.coverMimeType, 'image/png');
      }
    });

    test('gnre holds an ID3v1 genre number plus one', () {
      final r = readAudioTags(_b(m4aFile(udta: mp4Udta([mp4Item('gnre', 0, [0, 14])]))));
      expect(r.tags.genre, 'Pop');
    });

    test('an M4A without metadata reads as none', () {
      expect(readAudioTags(_b(m4aFile())).isEmpty, isTrue);
    });
  });

  group('WAV and AIFF', () {
    test('WAV id3 chunk wins over LIST/INFO, which fills the rest', () {
      final file = wavFile(extra: [
        riffInfo({'INAM': 'Info title', 'IART': 'Info artist', 'IPRD': 'Info album', 'ICRD': '2011', 'IGNR': 'Jazz', 'ICMT': 'Info note'}),
        riffChunk('id3 ', id3v2(3, [
          ('TIT2', id3TextContent(Id3Encoding.utf16Bom, ['ID3 title'])),
          ('APIC', id3PictureContent(jpeg)),
        ])),
      ]);
      final r = readAudioTags(_b(file));
      expect(r.tags.title, 'ID3 title');
      expect(r.tags.artist, 'Info artist');
      expect(r.tags.album, 'Info album');
      expect(r.tags.year, 2011);
      expect(r.tags.genre, 'Jazz');
      expect(r.tags.comment, 'Info note');
      expect(r.cover, jpeg);
    });

    test('WAV LIST/INFO alone, upper-case ID3 chunk alone', () {
      final info = readAudioTags(_b(wavFile(extra: [riffInfo({'INAM': 'Ünïcode', 'ITRK': '9'})])));
      expect(info.tags.title, 'Ünïcode');
      expect(info.tags.trackNumber, 9);
      final id3 = readAudioTags(_b(wavFile(extra: [riffChunk('ID3 ', id3v2(4, [('TIT2', id3TextContent(Id3Encoding.utf8, ['Upper']))]))])));
      expect(id3.tags.title, 'Upper');
    });

    test('AIFF ID3 chunk, and NAME/AUTH/ANNO text', () {
      final r = readAudioTags(_b(aiffFile(extra: [aiffChunk('ID3 ', id3v2(4, _v23Frames(Id3Encoding.utf8, jpeg)))])));
      _expectFull(r.tags);
      expect(r.cover, jpeg);
      final text = readAudioTags(_b(aiffFile(extra: [aiffChunk('NAME', ascii('Aiff name')), aiffChunk('AUTH', ascii('Aiff author')), aiffChunk('ANNO', ascii('Note'))])));
      expect(text.tags, const AudioTags(title: 'Aiff name', artist: 'Aiff author', comment: 'Note'));
    });
  });

  group('damaged files', () {
    final vectors = <String, Uint8List>{
      'id3v23': _b([...id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg)), ...mp3Frames(2), ...id3v1(title: 'v1')]),
      'id3v24 unsync': _b([...id3v2(4, _v23Frames(Id3Encoding.utf8, jpeg), unsync: true, extendedHeader: true), ...mp3Frames(2)]),
      'id3v22': _b([...id3v2(2, [('TT2', id3TextContent(Id3Encoding.latin1, ['x'])), ('PIC', id3v22PictureContent(jpeg))]), ...mp3Frames(1)]),
      'flac': _b(flacFile(comments: ['TITLE=t', 'ARTIST=a'], picture: jpeg, frames: 2)),
      'opus': _b(oggOpus(['TITLE=t', 'METADATA_BLOCK_PICTURE=${base64.encode(flacPicture(jpeg))}'])),
      'm4a': _b(m4aFile(frames: 4, udta: mp4Udta([mp4Text('©nam', 't'), mp4Item('covr', 13, jpeg)]))),
      'wav': _b(wavFile(dataBytes: 64, extra: [riffInfo({'INAM': 't'}), riffChunk('id3 ', id3v2(3, [('APIC', id3PictureContent(jpeg))]))])),
      'aiff': _b(aiffFile(extra: [aiffChunk('ID3 ', id3v2(3, [('TIT2', id3TextContent(Id3Encoding.latin1, ['t']))]))])),
    };

    test('cut off anywhere: never throws', () {
      for (final MapEntry(key: name, value: bytes) in vectors.entries) {
        final step = bytes.length > 4000 ? 7 : 1;
        for (var n = 0; n < bytes.length; n += step) {
          expect(() => readAudioTags(Uint8List.sublistView(bytes, 0, n)), returnsNormally, reason: '$name cut at $n');
        }
      }
    });

    test('random damage: never throws', () {
      final random = Random(1311);
      for (final MapEntry(key: name, value: bytes) in vectors.entries) {
        for (var round = 0; round < 300; round++) {
          final copy = Uint8List.fromList(bytes);
          final hits = 1 + random.nextInt(8);
          for (var i = 0; i < hits; i++) {
            // Mostly the tag area, where lengths live.
            final at = random.nextInt(min(copy.length, round.isEven ? 600 : copy.length));
            copy[at] = random.nextInt(256);
          }
          expect(() => readAudioTags(copy), returnsNormally, reason: '$name round $round');
        }
      }
    });

    test('random bytes behind every container signature: never throws', () {
      final random = Random(7);
      for (final head in ['ID3', 'fLaC', 'OggS', 'RIFF\x00\x00\x00\x00WAVE', 'FORM\x00\x00\x00\x00AIFF', '\x00\x00\x00\x18ftypM4A ']) {
        for (var round = 0; round < 200; round++) {
          final bytes = Uint8List.fromList([...latin1.encode(head), for (var i = 0; i < random.nextInt(400); i++) random.nextInt(256)]);
          expect(() => readAudioTags(bytes), returnsNormally);
        }
      }
    });

    test('what comes before the damage is kept', () {
      final full = id3v2(3, [
        ('TIT2', id3TextContent(Id3Encoding.latin1, ['Kept'])),
        ('TPE1', id3TextContent(Id3Encoding.latin1, ['Also kept'])),
        ('APIC', id3PictureContent(jpeg)),
      ]);
      // Cut in the middle of the picture: both texts survive.
      final r = readAudioTags(Uint8List.fromList(full.sublist(0, full.length - jpeg.length ~/ 2)));
      expect(r.tags.title, 'Kept');
      expect(r.tags.artist, 'Also kept');
      // A FLAC whose picture block is cut off still has its comments.
      final flac = flacFile(comments: ['TITLE=Flac kept'], picture: jpeg, frames: 0);
      expect(readAudioTags(Uint8List.fromList(flac.sublist(0, flac.length - 100))).tags.title, 'Flac kept');
    });
  });

  group('writing', () {
    const tags = AudioTags(
      title: 'Written — title',
      artist: 'Ärtist',
      album: 'Album',
      albumArtist: 'Album Artist',
      year: 2023,
      date: '2023-11-02',
      genre: 'Synthwave',
      trackNumber: 4,
      trackTotal: 10,
      discNumber: 2,
      composer: 'Composer',
      comment: 'A comment',
      lyrics: 'Words\nMore words',
    );

    test('MP3: the ID3v2.4 tag replaces the old tags in front, the audio is untouched', () {
      final audio = mp3Frames(5);
      final old = id3v2(3, [('TIT2', id3TextContent(Id3Encoding.latin1, ['Old'])), ('TPE1', id3TextContent(Id3Encoding.latin1, ['Old artist']))]);
      final written = embedAudioTags(_b([...old, ...old, ...audio]), AudioMimeTypes.mp3, tags, cover: jpeg, coverMimeType: 'image/jpeg')!;
      expect(written.sublist(0, 4), [0x49, 0x44, 0x33, 4]);
      final r = readAudioTags(written);
      expect(r.tags, tags);
      expect(r.cover, jpeg);
      expect(written.sublist(written.length - audio.length), audio);
      // Only one tag is left in front of the audio.
      final tagLength = 10 + ((written[6] & 0x7F) << 21 | (written[7] & 0x7F) << 14 | (written[8] & 0x7F) << 7 | (written[9] & 0x7F));
      expect(tagLength + audio.length, written.length);
    });

    test('MP3: writing again replaces, without growing', () {
      final once = embedAudioTags(_b(mp3Frames(3)), AudioMimeTypes.mp3, tags)!;
      final twice = embedAudioTags(once, AudioMimeTypes.mp3, tags)!;
      expect(twice, once);
    });

    for (final moovFirst in [true, false]) {
      test('M4A (moov ${moovFirst ? 'before' : 'after'} mdat): metadata added, chunk offsets still point at the samples', () {
        final file = _b(m4aFile(moovFirst: moovFirst, udta: mp4Udta([mp4Text('©nam', 'Old')])));
        final written = embedAudioTags(file, AudioMimeTypes.m4a, tags, cover: png, coverMimeType: 'image/png')!;
        final r = readAudioTags(written);
        expect(r.tags, tags);
        expect(r.cover, png);
        expect(r.coverMimeType, 'image/png');
        expect(_firstSample(written), _firstSample(file));
        expect(_firstSample(written), [0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C]);
      });
    }

    test('M4A without udta gets one; other udta boxes stay', () {
      final plain = _b(m4aFile());
      final r = readAudioTags(embedAudioTags(plain, AudioMimeTypes.m4a, const AudioTags(title: 'New'))!);
      expect(r.tags.title, 'New');
      final withOther = _b(m4aFile(udta: mp4Box('udta', [...mp4Box('©xyz', [0, 0, 0, 0, 1, 2, 3])])));
      final written = embedAudioTags(withOther, AudioMimeTypes.m4a, const AudioTags(title: 'New'))!;
      expect(latin1.decode(written, allowInvalid: true).contains('©xyz'), isTrue);
      expect(readAudioTags(written).tags.title, 'New');
    });

    test('formats NEFORUM does not tag, and damaged MP4s, give null', () {
      expect(embedAudioTags(_b(flacFile(comments: const [])), AudioMimeTypes.flac, tags), isNull);
      expect(embedAudioTags(_b(mp4Box('ftyp', ascii('M4A '))), AudioMimeTypes.m4a, tags), isNull);
      expect(embedAudioTags(_b([...mp4Box('ftyp', ascii('M4A ')), ...mp4Box('moov', []), ...mp4Box('moof', [])]), AudioMimeTypes.m4a, tags), isNull);
    });
  });

  group('track details as text', () {
    const all = AudioTags(title: 'Song', artist: 'Band', album: 'Record', albumArtist: 'Various', year: 2024, genre: 'Pop', trackNumber: 7);

    test('the default template, with details dropping out cleanly', () {
      expect(renderAudioText(kDefaultAudioTextTemplate, all), 'Band – Song (Record, 2024)');
      expect(renderAudioText(kDefaultAudioTextTemplate, const AudioTags(title: 'Song', artist: 'Band')), 'Band – Song');
      expect(renderAudioText(kDefaultAudioTextTemplate, const AudioTags(title: 'Song', artist: 'Band', year: 2024)), 'Band – Song (2024)');
      expect(renderAudioText(kDefaultAudioTextTemplate, const AudioTags(title: 'Song', album: 'Record')), 'Song (Record)');
      expect(renderAudioText(kDefaultAudioTextTemplate, const AudioTags(artist: 'Band', album: 'Record', year: 1999)), 'Band (Record, 1999)');
      expect(renderAudioText(kDefaultAudioTextTemplate, const AudioTags(album: 'Record')), '(Record)');
      expect(renderAudioText(kDefaultAudioTextTemplate, AudioTags.none), '');
      expect(renderAudioText(kDefaultAudioTextTemplate, const AudioTags(title: 'Song', date: '2021-03-04')), 'Song (2021)');
    });

    test('every token, lines, square brackets, plain bracketed words, unknown tokens', () {
      expect(renderAudioText('{track}. {title} by {artist} [{genre}] {albumArtist}', all), '7. Song by Band [Pop] Various');
      expect(renderAudioText('{track}. {title} by {artist} [{genre}]', const AudioTags(title: 'Song')), 'Song');
      expect(renderAudioText('New: {title} (live)\n{album}', const AudioTags(title: 'Song')), 'New: Song (live)');
      expect(renderAudioText('New: {title} (live)\nFrom {album}', const AudioTags(title: 'Song', album: 'Record')), 'New: Song (live)\nFrom Record');
      expect(renderAudioText('{artist}\nOut now: {title}', const AudioTags(title: 'Song')), 'Out now: Song');
      expect(renderAudioText('{title} {mood}', const AudioTags(title: 'Song')), 'Song {mood}');
      expect(renderAudioText('Listen: {title}!', AudioTags.none), '');
    });
  });

  group('AudioTags', () {
    const file = AudioTags(title: 'File title', artist: 'File artist', year: 2019, date: '2019-03-01', trackNumber: 2, coverPath: '/m/c.jpg', coverMimeType: 'image/jpeg');

    test('edits override, empty strings and 0 clear, a new year drops a stale date', () {
      final e = file.overriddenBy(const AudioTags(title: 'Mine', artist: '', trackNumber: 0, year: 2024));
      expect(e.title, 'Mine');
      expect(e.artist, isNull);
      expect(e.trackNumber, isNull);
      expect(e.year, 2024);
      expect(e.date, isNull);
      expect(e.coverPath, '/m/c.jpg');
      final removed = file.overriddenBy(const AudioTags(coverPath: ''));
      expect(removed.hasCover, isFalse);
      expect(removed.coverMimeType, isNull);
      expect(file.overriddenBy(const AudioTags(year: 2019)).date, '2019-03-01');
    });

    test('artist and title', () {
      expect(file.artistAndTitle, 'File artist – File title');
      expect(const AudioTags(title: 'T').artistAndTitle, 'T');
      expect(AudioTags.none.artistAndTitle, isNull);
    });
  });

  // Writes the vectors (and what the reader makes of them) for the check
  // against Windows' property system: NEFORUM_AUDIO_VECTORS=<folder>.
  final out = Platform.environment['NEFORUM_AUDIO_VECTORS'];
  test('write the vectors for the Windows property check', () {
    final dir = Directory(out!)..createSync(recursive: true);
    List<Id3FrameSpec> v24(Id3Encoding e, {Id3Encoding? described}) => [
          for (final f in _v23Frames(e, jpeg, itunes: false))
            if (f.$1 == 'TYER')
              ('TDRC', id3TextContent(e, ['2024-05-17']))
            else if (f.$1 == 'COMM' && described != null)
              ('COMM', id3DescribedContent(described, _full.comment!))
            else if (f.$1 == 'USLT' && described != null)
              ('USLT', id3DescribedContent(described, _full.lyrics!))
            else if (f.$1 != 'TDAT')
              f,
        ];
    final files = <String, List<int>>{
      'v23-utf16.mp3': [...id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg, itunes: false)), ...mp3Frames()],
      'v23-latin1.mp3': [
        ...id3v2(3, [
          ('TIT2', id3TextContent(Id3Encoding.latin1, ['Café Ø'])),
          ('TPE1', id3TextContent(Id3Encoding.latin1, ['Zoë'])),
          ('TALB', id3TextContent(Id3Encoding.latin1, ['Ålbum'])),
          ('TYER', id3TextContent(Id3Encoding.latin1, ['2001'])),
          ('TCON', id3TextContent(Id3Encoding.latin1, ['(17)Rock & Roll'])),
          ('TRCK', id3TextContent(Id3Encoding.latin1, ['9'])),
          ('COMM', id3DescribedContent(Id3Encoding.latin1, 'Latin note')),
          ('USLT', id3DescribedContent(Id3Encoding.latin1, 'Latin words')),
          ('APIC', id3PictureContent(back, type: 4)),
          ('APIC', id3PictureContent(jpeg)),
        ]),
        ...mp3Frames(),
      ],
      'v24-utf8.mp3': [...id3v2(4, v24(Id3Encoding.utf8)), ...mp3Frames()],
      'v24-utf8-utf16comm.mp3': [...id3v2(4, v24(Id3Encoding.utf8, described: Id3Encoding.utf16Bom)), ...mp3Frames()],
      'v24-utf16be.mp3': [...id3v2(4, v24(Id3Encoding.utf16be)), ...mp3Frames()],
      'v24-unsync-exthdr.mp3': [...id3v2(4, v24(Id3Encoding.utf8, described: Id3Encoding.utf16Bom), unsync: true, extendedHeader: true), ...mp3Frames()],
      'v23-unsync.mp3': [...id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg, itunes: false), unsync: true), ...mp3Frames()],
      'v23-itunnorm-first.mp3': [...id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg)), ...mp3Frames()],
      'v22.mp3': [
        ...id3v2(2, [
          ('TT2', id3TextContent(Id3Encoding.latin1, ['Old'])),
          ('TP1', id3TextContent(Id3Encoding.latin1, ['Artist 22'])),
          ('TAL', id3TextContent(Id3Encoding.latin1, ['Album 22'])),
          ('TYE', id3TextContent(Id3Encoding.latin1, ['1999'])),
          ('TCO', id3TextContent(Id3Encoding.latin1, ['(17)'])),
          ('TRK', id3TextContent(Id3Encoding.latin1, ['5/9'])),
          ('PIC', id3v22PictureContent(jpeg)),
        ]),
        ...mp3Frames(),
      ],
      'v1-only.mp3': [...mp3Frames(), ...id3v1(title: 'V1 title', artist: 'V1 artist', album: 'V1 album', year: '1987', comment: 'V1 note', track: 4, genre: 17)],
      'flac-picture.flac': flacFile(comments: [
        'TITLE=${_full.title}', 'ARTIST=${_full.artist}', 'ALBUM=${_full.album}', 'ALBUMARTIST=${_full.albumArtist}', 'DATE=2024-05-17',
        'GENRE=Pop', 'TRACKNUMBER=3', 'TRACKTOTAL=12', 'DISCNUMBER=1', 'COMPOSER=${_full.composer}', 'COMMENT=${_full.comment}',
      ], picture: jpeg),
      'ilst-covr.m4a': m4aFile(udta: mp4Udta([
        mp4Text('©nam', _full.title!), mp4Text('©ART', _full.artist!), mp4Text('©alb', _full.album!), mp4Text('aART', _full.albumArtist!),
        mp4Text('©day', '2024-05-17'), mp4Text('©gen', 'Pop'), mp4Item('trkn', 0, [0, 0, 0, 3, 0, 12, 0, 0]),
        mp4Item('disk', 0, [0, 0, 0, 1, 0, 2]), mp4Text('©wrt', _full.composer!), mp4Text('©cmt', _full.comment!), mp4Item('covr', 13, jpeg),
      ])),
      'ilst-covr-moov-last.m4a': m4aFile(moovFirst: false, udta: mp4Udta([
        mp4Text('©nam', 'Moov last'), mp4Text('©ART', 'Artist'), mp4Item('gnre', 0, [0, 18]), mp4Item('covr', 14, png),
      ])),
      'id3-chunk.wav': wavFile(extra: [riffChunk('id3 ', id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg, itunes: false)))]),
      'info-only.wav': wavFile(extra: [riffInfo({'INAM': 'Info title', 'IART': 'Info artist', 'IPRD': 'Info album', 'ICRD': '2011', 'IGNR': 'Jazz', 'ICMT': 'Info note'})]),
      'id3-chunk.aiff': aiffFile(extra: [aiffChunk('ID3 ', id3v2(3, _v23Frames(Id3Encoding.utf16Bom, jpeg, itunes: false)))]),
      'opus-tags.opus': oggOpus(['TITLE=Opus title', 'ARTIST=Opus artist', 'METADATA_BLOCK_PICTURE=${base64.encode(flacPicture(jpeg))}']),
      // NEFORUM's own writer, on silent audio built here.
      'written.mp3': embedAudioTags(_b(mp3Frames()), AudioMimeTypes.mp3, _full, cover: jpeg, coverMimeType: 'image/jpeg')!,
      'written.m4a': embedAudioTags(_b(m4aFile()), AudioMimeTypes.m4a, _full, cover: jpeg, coverMimeType: 'image/jpeg')!,
      'written-latin1.mp3': embedAudioTags(_b(mp3Frames()), AudioMimeTypes.mp3, const AudioTags(title: 'Plain', artist: 'Café', comment: 'Note', lyrics: 'Words'),
          cover: png, coverMimeType: 'image/png')!,
      'written-moov-last.m4a': embedAudioTags(_b(m4aFile(moovFirst: false)), AudioMimeTypes.m4a, _full, cover: png, coverMimeType: 'image/png')!,
    };
    final report = <String, Object?>{};
    for (final e in files.entries) {
      File('${dir.path}/${e.key}').writeAsBytesSync(e.value);
      report[e.key] = _readerJson(_b(e.value));
    }
    File('${dir.path}/reader.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  }, skip: out == null ? 'set NEFORUM_AUDIO_VECTORS to write them' : false);

  // Reads files given in NEFORUM_AUDIO_READ (separated by ';') and writes
  // what the reader finds to NEFORUM_AUDIO_READ_OUT.
  final readList = Platform.environment['NEFORUM_AUDIO_READ'];
  test('read the given files for the Windows property check', () {
    final report = <String, Object?>{
      for (final path in readList!.split(';').where((p) => p.isNotEmpty)) path: _readerJson(File(path).readAsBytesSync()),
    };
    File(Platform.environment['NEFORUM_AUDIO_READ_OUT']!).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  }, skip: readList == null ? 'set NEFORUM_AUDIO_READ to read them' : false);
}

Map<String, Object?> _readerJson(Uint8List bytes) {
  final r = readAudioTags(bytes);
  return {...r.tags.toJson(), if (r.cover != null) 'coverBytes': r.cover!.length, if (r.coverMimeType != null) 'coverMime': r.coverMimeType};
}

/// The bytes of the first sample, found through the first `stco` offset.
List<int> _firstSample(Uint8List file) {
  final text = latin1.decode(file, allowInvalid: true);
  final stco = text.indexOf('stco');
  final offset = ByteData.sublistView(file).getUint32(stco + 4 + 8);
  return file.sublist(offset, offset + 6);
}
