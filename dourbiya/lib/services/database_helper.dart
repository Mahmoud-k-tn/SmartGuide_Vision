import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  DatabaseHelper._internal();

  static final DatabaseHelper instance = DatabaseHelper._internal();

  static const _dbName = 'dourbiya_demo.db';
  static const _dbVersion = 1;

  static const _locationsTable = 'Locations';
  static const _obstaclesTable = 'Obstacles';

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<void> initialize() async {
    await database;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final dbFilePath = join(dbPath, _dbName);

    return openDatabase(
      dbFilePath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_locationsTable (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE $_obstaclesTable (
            id TEXT PRIMARY KEY,
            warning TEXT NOT NULL
          )
        ''');

        await _seedDemoData(db);
      },
      onOpen: (db) async {
        await _seedIfEmpty(db);
      },
    );
  }

  Future<void> _seedIfEmpty(Database db) async {
    final locationCount =
        Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $_locationsTable')) ?? 0;
    final obstacleCount =
        Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $_obstaclesTable')) ?? 0;

    if (locationCount == 0 || obstacleCount == 0) {
      await _seedDemoData(db);
    }
  }

  Future<void> _seedDemoData(Database db) async {
    await db.insert(
      _locationsTable,
      {
        'id': 'dorm_room_101',
        'name': 'Dorm Room',
        'description': 'You have arrived at your dorm room.',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await db.insert(
      _locationsTable,
      {
        'id': 'uni_cafeteria',
        'name': 'Cafeteria',
        'description': 'You are at the EPT Cafeteria. The counter is straight ahead.',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await db.insert(
      _locationsTable,
      {
        'id': 'uni_library',
        'name': 'Library',
        'description':
            'You are standing at the entrance of the university library. Please keep your voice down.',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await db.insert(
      _obstaclesTable,
      {
        'id': 'stairs_down',
        'warning': 'Attention, stairs going down straight ahead.',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await db.insert(
      _obstaclesTable,
      {
        'id': 'door_closed',
        'warning': 'Stop. There is a closed door in front of you.',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getLocationDescriptionById(String id) async {
    final db = await database;
    final rows = await db.query(
      _locationsTable,
      columns: ['description'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return rows.first['description'] as String;
  }

  Future<String?> getObstacleWarningById(String id) async {
    final db = await database;
    final rows = await db.query(
      _obstaclesTable,
      columns: ['warning'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return rows.first['warning'] as String;
  }

  Future<String?> getMessageByTriggerId(String id) async {
    final locationDescription = await getLocationDescriptionById(id);
    if (locationDescription != null) return locationDescription;

    final obstacleWarning = await getObstacleWarningById(id);
    if (obstacleWarning != null) return obstacleWarning;

    return null;
  }
}
