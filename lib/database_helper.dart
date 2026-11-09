import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'restaurant.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('local_hub.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 3, // <--- Incremented version because schema changed
      onCreate: _createDB,
      onUpgrade: _upgradeDB, // Handle the version change
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE must_try (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        rating TEXT NOT NULL,
        location TEXT NOT NULL,
        imageUrl TEXT NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        dateAdded TEXT NOT NULL,
        url TEXT NOT NULL,
        localImagePath TEXT,
        notes TEXT
      )
    ''');
  }

  // Simple upgrade function to recreate table if version changes
  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('DROP TABLE IF EXISTS must_try');
      await _createDB(db, newVersion);
    }
  }

  Future<void> addRestaurant(Restaurant restaurant) async {
    final db = await instance.database;
    await db.insert(
      'must_try',
      restaurant.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Restaurant>> getUserMustTryList() async {
    final db = await instance.database;
    final result = await db.query(
      'must_try',
      orderBy: 'dateAdded DESC',
    );
    return result.map((json) => Restaurant.fromMap(json)).toList();
  }

  Future<void> removeRestaurant(String restaurantId) async {
    final db = await instance.database;
    await db.delete(
      'must_try',
      where: 'id = ?',
      whereArgs: [restaurantId],
    );
  }

  Future<int> updateRestaurantImage(String id, String imagePath) async {
    Database db = await instance.database;
    return await db.update(
      'must_try', // <--- Fixed table name
      {'localImagePath': imagePath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

Future<int> updateRestaurantNotes(String id, String notes) async {
    Database db = await instance.database;
    return await db.update(
      'must_try',
      {'notes': notes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }


}