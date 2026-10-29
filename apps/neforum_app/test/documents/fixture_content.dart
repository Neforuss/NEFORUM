// The known content of the document fixtures. tool/generate_document_fixtures.dart
// writes the PDFs in test/fixtures/documents from it, and the tests compare
// what NEFORUM reads with it. Pure Dart (no Flutter), so the generator can
// run with `dart run`.

/// A block of a fixture, in reading order.
sealed class FixtureBlock {
  const FixtureBlock();
}

class FixtureHeading extends FixtureBlock {
  const FixtureHeading(this.text, {this.size = 16});
  final String text;
  final double size;
}

class FixtureParagraph extends FixtureBlock {
  const FixtureParagraph(this.text);
  final String text;
}

/// A picture: a solid colour (each fixture picture has its own, which is how
/// the tests recognise it), or a bar chart drawn with paths.
class FixtureImage extends FixtureBlock {
  const FixtureImage(this.name, {this.color = 0, this.chart = false, this.caption, required this.anchorPhrase, this.width = 200, this.height = 120});
  final String name;

  /// 0xRRGGBB.
  final int color;
  final bool chart;

  /// "Figure 2: ..." printed under the picture; becomes its description.
  final String? caption;

  /// Words of the paragraph the picture belongs with: the picture must be in
  /// the thread part holding them.
  final String anchorPhrase;
  final double width;
  final double height;
}

/// A fixture document: what it says, in reading order, and how it is laid
/// out (columns, running header and footer).
class FixtureDocument {
  const FixtureDocument({
    required this.file,
    required this.blocks,
    this.title,
    this.columns = 1,
    this.header,
    this.footer,
    this.logoColor,
    this.pages = 2,
    this.rotate = 0,
    this.cropX = 0,
    this.cropY = 0,
  });

  /// This document laid out the same, written to [file] on pages with
  /// /Rotate [rotate] (0, 90 or 270; the content is drawn turned the other
  /// way, so it reads upright once a viewer turns the page) and a crop box
  /// that starts at [cropX], [cropY] inside a larger media box (a print PDF
  /// with bleed).
  FixtureDocument withPageBox(String file, {int rotate = 0, double cropX = 0, double cropY = 0}) => FixtureDocument(
        file: file,
        blocks: blocks,
        title: title,
        columns: columns,
        header: header,
        footer: footer,
        logoColor: logoColor,
        pages: pages,
        rotate: rotate,
        cropX: cropX,
        cropY: cropY,
      );

  final String file;

  /// Printed across the full width above the columns.
  final FixtureHeading? title;
  final List<FixtureBlock> blocks;
  final int columns;

  /// Printed at the top of every page (not part of the text).
  final String? header;

  /// Printed at the bottom of every page; `#` becomes the page number and
  /// `%` the page count.
  final String? footer;

  /// A small logo of this colour at the top of every page (a decoration).
  final int? logoColor;

  /// Pages at least (the text flows on to more when it needs them).
  final int pages;

  /// The pages' /Rotate and crop box origin ([withPageBox]).
  final int rotate;
  final double cropX, cropY;

  Iterable<FixtureImage> get images => blocks.whereType<FixtureImage>();

  /// Every word of the text in reading order: title, headings and
  /// paragraphs, without captions, header or footer.
  List<String> get words => [
        if (title != null) ...title!.text.split(' '),
        for (final b in blocks)
          ...switch (b) {
            FixtureHeading(:final text) => text.split(' '),
            FixtureParagraph(:final text) => text.split(' '),
            FixtureImage() => const <String>[],
          },
      ].where((w) => w.isNotEmpty).toList();
}

const _p1 = 'The workshop opened with a short welcome from the organisers, who explained how the week would run and why '
    'the sessions had been arranged around practical exercises rather than lectures. Everyone received a printed '
    'schedule, a notebook and a small box of tools for the afternoon projects.';
const _p2 = 'On the first morning the participants measured the old garden walls, recorded the height of every course of '
    'stone and compared their notes with the drawings made by the previous group. Several discrepancies appeared, '
    'mostly where later repairs had replaced the original masonry with concrete blocks.';
const _p3 = 'The second session looked at drainage. As Figure 2 shows, the lower field stays wet long after rain, because '
    'the ditch along the hedge has silted up and the culvert under the track is partly blocked by roots and fallen '
    'branches. Clearing both would let the water reach the stream again.';
const _p4 = 'In the afternoon the group walked the boundary with the landowner, who pointed out the places where the '
    'fence had failed during the winter storms. The discussion turned to whether a hedge would be a better long-term '
    'answer than another fence, given the cost of posts and wire.';
const _p5 = 'Figure 3 compares the number of volunteers who came each month with the number of hours they worked. The '
    'busiest months were in late spring, when the weather was mild and the days were long enough for evening work '
    'after people finished their jobs.';
const _p6 = 'The notes from each session were typed up the same evening and shared with everyone, so that the people who '
    'missed a day could still follow the decisions. This habit turned out to be one of the most useful parts of the '
    'whole week, and the group agreed to keep it.';
const _p7 = 'On the final day the participants presented their recommendations to the parish council. The council '
    'thanked them for the careful work and promised to discuss the drainage proposal at its next meeting, together '
    'with the estimate for the new hedge along the northern boundary.';

/// One column, pictures between paragraphs, captions and a drawn chart.
const singleColumnFixture = FixtureDocument(
  file: 'single_column_images.pdf',
  blocks: [
    FixtureHeading('Notes from the Workshop', size: 18),
    FixtureParagraph(_p1),
    FixtureImage('red', color: 0xD62828, anchorPhrase: 'tools for the afternoon projects'),
    FixtureParagraph(_p2),
    FixtureParagraph(_p3),
    FixtureParagraph(_p4),
    FixtureHeading('Results and Next Steps', size: 14),
    FixtureParagraph(_p5),
    FixtureImage('green', color: 0x2A9D3F, caption: 'Figure 2: The lower field after rain', anchorPhrase: 'As Figure 2 shows'),
    FixtureParagraph(_p6),
    FixtureImage('chart', chart: true, caption: 'Figure 3: Volunteers and hours by month', anchorPhrase: 'Figure 3 compares the number', width: 260, height: 150),
    FixtureParagraph(_p7),
    FixtureImage('blue', color: 0x1D4ED8, anchorPhrase: 'along the northern boundary'),
  ],
);

const _c1 = 'The survey began at the northern gate, where the path divides into three tracks. Each track was walked twice, '
    'once in the morning and once in the late afternoon, and the observers noted every bird they heard or saw within '
    'twenty metres of the path.';
const _c2 = 'Along the eastern track the hedges are tall and dense, and the most common birds were wrens, robins and '
    'blackbirds. The observers also recorded a pair of bullfinches feeding on the buds of the blackthorn near the old '
    'stile, which had not been seen there for several years.';
const _c3 = 'The western track crosses open grassland. Skylarks sang over the meadow on both visits, and a kestrel hunted '
    'along the margin of the field for most of the afternoon. Meadow pipits were present in small numbers near the '
    'wet ground by the pond.';
const _c4 = 'The central track runs through the wood. Here the counts were lower, but the variety was greater: great '
    'spotted woodpeckers, nuthatches, treecreepers and a single tawny owl roosting in an ivy-covered oak close to the '
    'ruined keeper cottage.';
const _c5 = 'Compared with last year, the number of species recorded rose from thirty-one to thirty-six. The observers '
    'believe the new pond and the uncut field margins are the main reasons, since several of the new species depend '
    'on insects that breed in wet ground and long grass.';
const _c6 = 'Several observers suggested extending the survey into the evening, because owls and bats were heard at '
    'dusk but could not be counted properly. The photographs of the pond margin, see Figure 1, show how much the '
    'vegetation has grown since the spring.';
const _c7 = 'The committee will repeat the survey next summer with the same routes and timings, so that the results can '
    'be compared fairly. Volunteers who would like to join should contact the secretary before the end of the '
    'month, and new observers are always welcome.';
const _c8 = 'Finally, the group thanked the landowners for permission to walk the tracks, and the local school for '
    'lending binoculars to the younger volunteers who joined the morning walks during the holiday week.';

const _c9 = 'The evening walks began in August. Two observers with torches followed the central track after sunset and '
    'listened at five fixed points for ten minutes each, noting owls, nightjars and anything else that called.';
const _c10 = 'Tawny owls were heard at every point on every evening, often several at once, and a barn owl was seen '
    'quartering the meadow beside the western track on two occasions. Nightjars were not recorded this year.';
const _c11 = 'Bats were counted with a borrowed detector. Common and soprano pipistrelles fed along the hedges, and '
    'noctules flew high over the pond shortly after sunset. The detector also picked up a brown long-eared bat near '
    'the cottage ruins.';
const _c12 = 'These results will be sent to the county recorder, together with the daytime counts, so that they can be '
    'added to the regional atlas. Copies of the full tables are available from the secretary on request.';

/// Two columns under a full-width title; the text flows down the left
/// column, then the right, and on to both columns of a second page.
const twoColumnFixture = FixtureDocument(
  file: 'two_columns.pdf',
  columns: 2,
  title: FixtureHeading('Summer Bird Survey Report', size: 20),
  blocks: [
    FixtureParagraph(_c1),
    FixtureParagraph(_c2),
    FixtureImage('orange', color: 0xF77F00, anchorPhrase: 'not been seen there for several years', width: 180, height: 110),
    FixtureParagraph(_c3),
    FixtureParagraph(_c4),
    FixtureHeading('Changes Since Last Year', size: 14),
    FixtureParagraph(_c5),
    FixtureParagraph(_c6),
    FixtureParagraph(_c7),
    FixtureImage('purple', color: 0x7B2CBF, caption: 'Figure 1: The pond margin in July', anchorPhrase: 'see Figure 1', width: 180, height: 110),
    FixtureParagraph(_c8),
    FixtureHeading('Evening Walks', size: 14),
    FixtureParagraph(_c9),
    FixtureParagraph(_c10),
    FixtureParagraph(_c13),
    FixtureParagraph(_c11),
    FixtureImage('brown', color: 0x8B5A2B, anchorPhrase: 'near the cottage ruins', width: 180, height: 110),
    FixtureParagraph(_c14),
    FixtureParagraph(_c12),
    FixtureParagraph(_c15),
    FixtureParagraph(_c16),
  ],
);

const _c13 = 'On the warmest evening the observers stayed until midnight. Moths gathered around the torches in such '
    'numbers that one volunteer began counting them as well, and the group now hopes to borrow a light trap.';
const _c14 = 'Hedgehogs crossed the track twice, and a fox watched the observers from the edge of the wood for several '
    'minutes before slipping away towards the farm. Neither had been noted on the daytime walks.';
const _c15 = 'The cost of the season was small: batteries for the torches, a new notebook for each observer and the hire '
    'of the detector for a fortnight. The society paid for all of it from the summer raffle.';
const _c16 = 'Anyone interested in the evening walks next year should know that warm clothes and patience matter more '
    'than experience. The owls, it turns out, are happy to be counted by beginners.';

const _h1 = 'This bulletin collects the news from the allotment society for the last three months. It is printed for '
    'members who do not use email, and copies are left in the shed by the main gate for anyone who wants one.';
const _h2 = 'The water supply was turned on again in early April after the repairs to the main pipe. Members are asked to '
    'use watering cans rather than hoses during dry spells, so that the plots at the far end of the site still have '
    'enough pressure in the evenings.';
const _h3 = 'The plant sale raised more money than in any previous year. Thanks go to everyone who grew seedlings, baked '
    'cakes or helped on the day. The money will pay for a new lock on the gate and fresh gravel for the main path.';
const _h4 = 'Several plots changed hands this season. New members are welcome to ask the committee for advice, and the '
    'society keeps a small library of gardening books in the shed which anyone may borrow for a month at a time.';
const _h5 = 'The marker posts at the end of each row have been repainted, as shown in Figure 1, so that visitors can find '
    'the plot numbers more easily. Please do not move the posts when digging, and report any that have been damaged.';
const _h6 = 'The autumn meeting will be held in the village hall on the first Saturday of October. The agenda includes '
    'the election of officers, the accounts for the year and a proposal to build a second compost bay near the '
    'western hedge.';
const _h7 = 'Members who have surplus produce are reminded that the food bank in the town accepts fresh vegetables on '
    'Tuesday and Friday mornings. Last year the society gave more than two hundred kilograms of potatoes, beans and '
    'squash.';
const _h8 = 'Finally, the committee would like to thank the retiring treasurer for eleven years of careful work. A small '
    'presentation will take place after the autumn meeting, and all members are invited to stay for tea.';

/// Three pages with a running header, a small logo on every page and a
/// "Page N of 3" footer, none of which belongs in the thread.
const headersFootersFixture = FixtureDocument(
  file: 'headers_footers.pdf',
  pages: 3,
  header: 'Allotment Society Quarterly Bulletin',
  footer: 'Page # of %',
  logoColor: 0x0E9AA7,
  blocks: [
    FixtureHeading('Spring and Summer News', size: 18),
    FixtureParagraph(_h1),
    FixtureParagraph(_h2),
    FixtureParagraph(_h3),
    FixtureHeading('Plots and Paths', size: 14),
    FixtureParagraph(_h4),
    FixtureParagraph(_h5),
    FixtureParagraph(_h6),
    FixtureImage('yellow', color: 0xF2C200, caption: 'Figure 1: A repainted marker post', anchorPhrase: 'as shown in Figure 1', width: 200, height: 150),
    FixtureHeading('Coming Up', size: 14),
    FixtureParagraph(_h7),
    FixtureParagraph(_h8),
    FixtureHeading('From the Plots', size: 14),
    FixtureParagraph(_h9),
    FixtureParagraph(_h10),
    FixtureParagraph(_h11),
    FixtureParagraph(_h12),
    FixtureParagraph(_h13),
    FixtureParagraph(_h14),
  ],
);

const _h9 = 'Plot twelve produced the heaviest marrow anyone can remember. Its grower credits a load of manure from the '
    'riding stables and a great deal of rainwater collected from the shed roof in old barrels.';
const _h10 = 'Slugs were a problem everywhere in the wet weeks of June. Several members tried beer traps, copper tape and '
    'nightly patrols with a torch, and the patrols, though tiring, seemed to work best of all.';
const _h11 = 'The beehives at the northern end have done well. The keeper expects a good harvest in September and will '
    'sell jars at the autumn meeting, with the proceeds going towards a new roof for the shed.';
const _h12 = 'A family of foxes has moved into the bramble patch behind plot thirty. They are welcome to stay, but members '
    'are asked to keep netting secure and to close the gate behind them, especially in the evening.';
const _h13 = 'The communal tool store now has a sign-out sheet. Please write down what you borrow and return it clean, '
    'because several spades went missing over the summer and one fork came back with a broken handle.';
const _h14 = 'Seed swapping will happen on the last Sunday of November in the shed. Bring labelled envelopes with the '
    'variety and the year, and take home something new to try next season.';

/// The PDF fixtures with text.
const pdfFixtures = [singleColumnFixture, twoColumnFixture, headersFootersFixture];

/// The same documents on turned pages and inside a bleed: PDFium measures
/// the page as displayed but reports text and picture boxes in the
/// unturned, uncropped page space, and they must read exactly the same.
final pageBoxFixtures = [
  twoColumnFixture.withPageBox('two_columns_rotated.pdf', rotate: 90),
  singleColumnFixture.withPageBox('single_column_images_cropped.pdf', cropX: 36, cropY: 48),
  singleColumnFixture.withPageBox('single_column_images_rotated.pdf', rotate: 270, cropX: 24, cropY: 30),
];

/// A one-page PDF that is only a picture of a page (a scan without text).
const scannedFixtureFile = 'scanned.pdf';
