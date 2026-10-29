import 'package:meta/meta.dart';

/// What a sound file says about itself (ID3 frames, Vorbis comments, MP4
/// atoms, WAV and AIFF chunks), or what the user typed for a file that says
/// nothing. Every field is optional.
///
/// The cover is a picture file in NEFORUM's media folder ([coverPath]), so
/// posts that keep the tags keep the cover with them.
@immutable
class AudioTags {
  const AudioTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.year,
    this.date,
    this.genre,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.composer,
    this.comment,
    this.lyrics,
    this.coverPath,
    this.coverMimeType,
  });

  factory AudioTags.fromJson(Map<String, dynamic> json) => AudioTags(
        title: json['title'] as String?,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        albumArtist: json['albumArtist'] as String?,
        year: json['year'] as int?,
        date: json['date'] as String?,
        genre: json['genre'] as String?,
        trackNumber: json['trackNumber'] as int?,
        trackTotal: json['trackTotal'] as int?,
        discNumber: json['discNumber'] as int?,
        composer: json['composer'] as String?,
        comment: json['comment'] as String?,
        lyrics: json['lyrics'] as String?,
        coverPath: json['coverPath'] as String?,
        coverMimeType: json['coverMimeType'] as String?,
      );

  static const AudioTags none = AudioTags();

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;

  /// The release year (ID3 TYER/TDRC, Vorbis DATE, MP4 ©day).
  final int? year;

  /// The full release date as written in the file (`2024-05-17`), when it is
  /// more than a year.
  final String? date;
  final String? genre;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final String? composer;
  final String? comment;
  final String? lyrics;

  /// The front cover, copied into NEFORUM's media folder.
  final String? coverPath;
  final String? coverMimeType;

  bool get hasCover => coverPath != null && coverPath!.isNotEmpty;

  /// "Artist – Title", "Title" or "Artist"; null when neither is set. The
  /// one-line name of the track (alt text, link titles).
  String? get artistAndTitle {
    final a = artist?.trim() ?? '', t = title?.trim() ?? '';
    if (a.isEmpty && t.isEmpty) return null;
    if (a.isEmpty) return t;
    if (t.isEmpty) return a;
    return '$a – $t';
  }

  bool get isEmpty =>
      title == null &&
      artist == null &&
      album == null &&
      albumArtist == null &&
      year == null &&
      date == null &&
      genre == null &&
      trackNumber == null &&
      trackTotal == null &&
      discNumber == null &&
      composer == null &&
      comment == null &&
      lyrics == null &&
      coverPath == null;

  /// These tags with every field [over] sets taking its place (the user's
  /// edits over the file's own tags).
  ///
  /// In [over], an empty string (or an empty [coverPath]) and the number 0
  /// mean "removed": the user cleared what the file says. A year set without
  /// a date drops a file date of another year.
  AudioTags overriddenBy(AudioTags? over) {
    if (over == null) return this;
    String? text(String? edit, String? own) => edit == null ? own : (edit.isEmpty ? null : edit);
    int? number(int? edit, int? own) => edit == null ? own : (edit <= 0 ? null : edit);
    final cover = over.coverPath;
    final y = number(over.year, year);
    var d = text(over.date, date);
    if (over.date == null && over.year != null && d != null && !d.startsWith('$y')) d = null;
    return AudioTags(
      title: text(over.title, title),
      artist: text(over.artist, artist),
      album: text(over.album, album),
      albumArtist: text(over.albumArtist, albumArtist),
      year: y,
      date: d,
      genre: text(over.genre, genre),
      trackNumber: number(over.trackNumber, trackNumber),
      trackTotal: number(over.trackTotal, trackTotal),
      discNumber: number(over.discNumber, discNumber),
      composer: text(over.composer, composer),
      comment: text(over.comment, comment),
      lyrics: text(over.lyrics, lyrics),
      coverPath: cover == null ? coverPath : (cover.isEmpty ? null : cover),
      coverMimeType: cover == null ? coverMimeType : (cover.isEmpty ? null : over.coverMimeType),
    );
  }

  /// These tags with [coverPath] (and its type) replaced, for the copy made
  /// when the cover is saved to a file.
  AudioTags withCover(String? path, String? mimeType) => AudioTags(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        year: year,
        date: date,
        genre: genre,
        trackNumber: trackNumber,
        trackTotal: trackTotal,
        discNumber: discNumber,
        composer: composer,
        comment: comment,
        lyrics: lyrics,
        coverPath: path,
        coverMimeType: path == null ? null : mimeType,
      );

  Map<String, dynamic> toJson() => {
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (albumArtist != null) 'albumArtist': albumArtist,
        if (year != null) 'year': year,
        if (date != null) 'date': date,
        if (genre != null) 'genre': genre,
        if (trackNumber != null) 'trackNumber': trackNumber,
        if (trackTotal != null) 'trackTotal': trackTotal,
        if (discNumber != null) 'discNumber': discNumber,
        if (composer != null) 'composer': composer,
        if (comment != null) 'comment': comment,
        if (lyrics != null) 'lyrics': lyrics,
        if (coverPath != null) 'coverPath': coverPath,
        if (coverMimeType != null) 'coverMimeType': coverMimeType,
      };

  @override
  bool operator ==(Object other) => other is AudioTags && _mapEquals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAll(toJson().entries.map((e) => Object.hash(e.key, e.value)));

  static bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}
