import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/enums.dart';

/// Tags are stored as a JSON array of strings, per SPEC.md §6.
class TagsConverter extends TypeConverter<List<String>, String> {
  const TagsConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    final decoded = jsonDecode(fromDb);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is String) item,
    ];
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

class CaptureStatusConverter extends TypeConverter<CaptureStatus, String> {
  const CaptureStatusConverter();

  @override
  CaptureStatus fromSql(String fromDb) => CaptureStatus.fromWire(fromDb);

  @override
  String toSql(CaptureStatus value) => value.wire;
}

class NoteTypeConverter extends TypeConverter<NoteType, String> {
  const NoteTypeConverter();

  @override
  NoteType fromSql(String fromDb) =>
      NoteType.tryParse(fromDb) ??
      (throw ArgumentError('Unknown note type in database: $fromDb'));

  @override
  String toSql(NoteType value) => value.name;
}

class ChangeSourceConverter extends TypeConverter<ChangeSource, String> {
  const ChangeSourceConverter();

  @override
  ChangeSource fromSql(String fromDb) => ChangeSource.fromWire(fromDb);

  @override
  String toSql(ChangeSource value) => value.wire;
}
