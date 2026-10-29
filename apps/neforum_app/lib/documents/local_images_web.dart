import 'dart:typed_data';

/// The web preview cannot read files next to a document.
Uint8List? Function(String src)? localImageLoader(String? folder) => null;
