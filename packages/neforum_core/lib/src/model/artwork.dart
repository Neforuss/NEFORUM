import 'package:meta/meta.dart';

/// Audience rating of a piece of artwork, mapped onto each art site's own
/// scale (DeviantArt mature levels, Itaku SFW/Questionable/NSFW, ...).
enum ArtworkMaturity {
  /// Suitable for everyone.
  general,

  /// Suggestive themes, mild nudity or violence.
  mature,

  /// Explicit content; only sites that allow it receive the post.
  adult,
}

/// Marks a post as artwork. Artwork posts go to art portfolio sites
/// (PlatformCategory.art); the post's title and tags are the work's title
/// and tags, and its text is the description.
@immutable
class ArtworkDetails {
  const ArtworkDetails({
    this.maturity = ArtworkMaturity.general,
    this.aiGenerated = false,
    this.disallowAiTraining = true,
  });

  factory ArtworkDetails.fromJson(Map<String, dynamic> json) => ArtworkDetails(
        maturity: ArtworkMaturity.values.asNameMap()[json['maturity']] ?? ArtworkMaturity.general,
        aiGenerated: json['aiGenerated'] as bool? ?? false,
        disallowAiTraining: json['disallowAiTraining'] as bool? ?? true,
      );

  final ArtworkMaturity maturity;

  /// The work was made with generative AI tools. Several sites require this
  /// label; some refuse such work.
  final bool aiGenerated;

  /// Ask the site to keep the work out of AI training sets (DeviantArt
  /// NoAI, ArtStation NoAI tag) where it offers that.
  final bool disallowAiTraining;

  ArtworkDetails copyWith({ArtworkMaturity? maturity, bool? aiGenerated, bool? disallowAiTraining}) => ArtworkDetails(
        maturity: maturity ?? this.maturity,
        aiGenerated: aiGenerated ?? this.aiGenerated,
        disallowAiTraining: disallowAiTraining ?? this.disallowAiTraining,
      );

  Map<String, dynamic> toJson() => {
        'maturity': maturity.name,
        'aiGenerated': aiGenerated,
        'disallowAiTraining': disallowAiTraining,
      };

  @override
  bool operator ==(Object other) =>
      other is ArtworkDetails &&
      other.maturity == maturity &&
      other.aiGenerated == aiGenerated &&
      other.disallowAiTraining == disallowAiTraining;

  @override
  int get hashCode => Object.hash(maturity, aiGenerated, disallowAiTraining);
}
