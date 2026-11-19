import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';

void main() {
  test('folder location splits its path for breadcrumbs', () {
    const location = FolderLocation(
      sourceId: 7,
      sourceName: 'NAS',
      path: 'Artist/Album 10',
    );

    expect(location.name, 'Album 10');
    expect(location.segments, ['Artist', 'Album 10']);
    expect(location.pathAt(0), '');
    expect(location.pathAt(1), 'Artist');
    expect(location.pathAt(2), 'Artist/Album 10');
    expect(folderKeyOf(location), (sourceId: 7, path: 'Artist/Album 10'));
  });

  test('folder root is named after its source', () {
    const location = FolderLocation(sourceId: 7, sourceName: 'NAS', path: '');
    expect(location.name, 'NAS');
    expect(location.segments, isEmpty);
    expect(location.pathAt(0), '');
  });
}
