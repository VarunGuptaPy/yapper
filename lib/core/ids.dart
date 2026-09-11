import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// A fresh v4 UUID. Used for every primary key in the app.
String newId() => _uuid.v4();
