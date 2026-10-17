/// A link that opens the app on a place, e.g. from a QR poster:
///
///   campusnav://campus/to/library                 directions to the Library
///   campusnav://campus/to/library?from=gate_main  ... starting at the Main Gate
///   campusnav://campus/from/a0_adminlobby         "you are at the Admin Lobby"
///
/// Android hands the app only the path ("/to/library?from=gate_main"); the
/// in-app scanner sees the whole link. Both are accepted, and so is the short
/// form campusnav://to/library.
class DeepLink {
  final String? to; // place id
  final String? from; // node id of the start

  const DeepLink({this.to, this.from});

  static final _id = RegExp(r'^[A-Za-z0-9_\-]+$');

  static String? _clean(String? id) => id != null && _id.hasMatch(id) ? id : null;

  static DeepLink? parse(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      return null;
    }
    var parts = [for (final p in uri.pathSegments) if (p.isNotEmpty) p];
    if (uri.scheme == 'campusnav' && (uri.host == 'to' || uri.host == 'from')) {
      parts = [uri.host, ...parts];
    }
    if (parts.length < 2) return null;

    final id = _clean(parts[1]);
    if (id == null) return null;
    switch (parts[0]) {
      case 'to':
        return DeepLink(to: id, from: _clean(uri.queryParameters['from']));
      case 'from':
        return DeepLink(from: id);
      default:
        return null;
    }
  }

  /// The link for a place, for printing on posters.
  static String forPlace(String placeId, {String? from}) =>
      'campusnav://campus/to/$placeId${from == null ? '' : '?from=$from'}';
}
