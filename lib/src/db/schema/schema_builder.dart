import '../persistent_store/persistent_store.dart';
import 'schema.dart';

/*
Tests for this class are spread out some. The testing concept used starts by understanding that
that each method invoked on the builder (e.g. createTable, addColumn) adds a statement to [commands].
A statement is either:

a) A Dart statement that replicate the command to build migration code
b) A SQL command when running a migration

In effect, the generated Dart statement is the source code for the invoked method. Each method invoked on a
builder is tested so that the generated Dart code is equivalent
to the invocation. These tests are in generate_code_test.dart.

The code to ensure the generated SQL is accurate is in db/postgresql/schema_generator_sql_mapping_test.dart.

The logic that goes into testing that the commands generated to build a valid schema in an actual postgresql are in db/postgresql/migration_test.dart.
 */

/// Generates SQL or Dart code that modifies a database schema.
class SchemaBuilder {
  /// Creates a builder starting from an existing schema.
  ///
  /// If [store] is null, this builder will emit [commands] that are Dart statements that replicate the methods invoked on this object.
  /// Otherwise, [commands] are SQL commands (for the database represented by [store]) that are equivalent to the method invoked on this object.
  SchemaBuilder(this.store, this.inputSchema, {this.isTemporary = false}) {
    schema = Schema.from(inputSchema);
  }

  /// Creates a builder starting from the empty schema.
  ///
  /// If [store] is null, this builder will emit [commands] that are Dart statements that replicate the methods invoked on this object.
  ///  Otherwise, [commands] are SQL commands (for the database represented by [store]) that are equivalent to the method invoked on this object.
  SchemaBuilder.toSchema(PersistentStore store, Schema targetSchema,
      {bool isTemporary = false, List<String> changeList})
      : this.fromDifference(
            store, SchemaDifference(Schema.empty(), targetSchema),
            isTemporary: isTemporary, changeList: changeList);

  // Creates a builder
  SchemaBuilder.fromDifference(this.store, SchemaDifference difference,
      {this.isTemporary = false, List<String> changeList}) {
    schema = difference.expectedSchema;
    _generateSchemaCommands(difference,
        changeList: changeList, temporary: isTemporary);
  }

  /// The starting schema of this builder.
  Schema inputSchema;

  /// The resulting schema of this builder as operations are applied to it.
  Schema schema;

  /// The persistent store to validate and construct operations.
  ///
  /// If this value is not-null, [commands] is a list of SQL commands for the underlying database that change the schema in response to
  /// methods invoked on this object. If this value is null, [commands] is a list Dart statements that replicate the methods invoked on this object.
  PersistentStore store;

  /// Whether or not this builder should create temporary tables.
  bool isTemporary;

  /// A list of commands generated by operations performed on this builder.
  ///
  /// If [store] is non-null, these commands will be SQL commands that upgrade [inputSchema] to [schema] as determined by [store].
  /// If [store] is null, these commands are ;-terminated Dart expressions that replicate the methods to call on this object to upgrade [inputSchema] to [schema].
  List<String> commands = [];

  /// Validates and adds a table to [schema].
  void createTable(SchemaTable table) {
    schema.addTable(table);

    if (store != null) {
      commands.addAll(store.createTable(table, isTemporary: isTemporary));
    } else {
      commands.add(_getNewTableExpression(table));
    }
  }

  /// Validates and renames a table in [schema].
  void renameTable(String currentTableName, String newName) {
    var table = schema.tableForName(currentTableName);
    if (table == null) {
      throw SchemaException("Table $currentTableName does not exist.");
    }

    schema.renameTable(table, newName);
    if (store != null) {
      commands.addAll(store.renameTable(table, newName));
    } else {
      commands.add("database.renameTable('$currentTableName', '$newName');");
    }
  }

  /// Validates and deletes a table in [schema].
  void deleteTable(String tableName) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw SchemaException("Table $tableName does not exist.");
    }

    schema.removeTable(table);

    if (store != null) {
      commands.addAll(store.deleteTable(table));
    } else {
      commands.add('database.deleteTable("${tableName}");');
    }
  }

  /// Alters a table in [schema].
  void alterTable(String tableName, void modify(SchemaTable targetTable)) {
    var existingTable = schema.tableForName(tableName);
    if (existingTable == null) {
      throw SchemaException("Table $tableName does not exist.");
    }

    var newTable = SchemaTable.from(existingTable);
    modify(newTable);
    schema.replaceTable(existingTable, newTable);

    final shouldAddUnique = existingTable.uniqueColumnSet == null &&
        newTable.uniqueColumnSet != null;
    final shouldRemoveUnique = existingTable.uniqueColumnSet != null &&
        newTable.uniqueColumnSet == null;

    final innerCommands = <String>[];
    if (shouldAddUnique) {
      if (store != null) {
        commands.addAll(store.addTableUniqueColumnSet(newTable));
      } else {
        innerCommands.add(
            "t.uniqueColumnSet = [${newTable.uniqueColumnSet.map((s) => "\"$s\"").join(',')}]");
      }
    } else if (shouldRemoveUnique) {
      if (store != null) {
        commands.addAll(store.deleteTableUniqueColumnSet(newTable));
      } else {
        innerCommands.add("t.uniqueColumnSet = null");
      }
    } else {
      final haveSameLength = existingTable.uniqueColumnSet.length ==
          newTable.uniqueColumnSet.length;
      final haveSameKeys = existingTable.uniqueColumnSet
          .every((s) => newTable.uniqueColumnSet.contains(s));

      if (!haveSameKeys || !haveSameLength) {
        if (store != null) {
          commands.addAll(store.deleteTableUniqueColumnSet(newTable));
          commands.addAll(store.addTableUniqueColumnSet(newTable));
        } else {
          innerCommands.add(
              "t.uniqueColumnSet = [${newTable.uniqueColumnSet.map((s) => "\"$s\"").join(',')}]");
        }
      }
    }

    if (store == null && innerCommands.isNotEmpty) {
      commands.add(
          "database.alterTable(\"$tableName\", (t) {${innerCommands.join(";")};});");
    }
  }

  /// Validates and adds a column to a table in [schema].
  void addColumn(String tableName, SchemaColumn column,
      {String unencodedInitialValue}) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw SchemaException("Table $tableName does not exist.");
    }

    table.addColumn(column);
    if (store != null) {
      commands.addAll(store.addColumn(table, column,
          unencodedInitialValue: unencodedInitialValue));
    } else {
      commands.add(
          'database.addColumn("${column.table.name}", ${_getNewColumnExpression(column)});');
    }
  }

  /// Validates and deletes a column in a table in [schema].
  void deleteColumn(String tableName, String columnName) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw SchemaException("Table $tableName does not exist.");
    }

    var column = table.columnForName(columnName);
    if (column == null) {
      throw SchemaException("Column $columnName does not exists.");
    }

    table.removeColumn(column);

    if (store != null) {
      commands.addAll(store.deleteColumn(table, column));
    } else {
      commands.add('database.deleteColumn("${tableName}", "${columnName}");');
    }
  }

  /// Validates and renames a column in a table in [schema].
  void renameColumn(String tableName, String columnName, String newName) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw SchemaException("Table $tableName does not exist.");
    }

    var column = table.columnForName(columnName);
    if (column == null) {
      throw SchemaException("Column $columnName does not exists.");
    }

    table.renameColumn(column, newName);

    if (store != null) {
      commands.addAll(store.renameColumn(table, column, newName));
    } else {
      commands.add(
          "database.renameColumn('$tableName', '$columnName', '$newName');");
    }
  }

  /// Validates and alters a column in a table in [schema].
  ///
  /// Alterations are made by setting properties of the column passed to [modify]. If the column's nullability
  /// changes from nullable to not nullable,  all previously null values for that column
  /// are set to the value of [unencodedInitialValue].
  ///
  /// Example:
  ///
  ///         database.alterColumn("table", "column", (c) {
  ///           c.isIndexed = true;
  ///           c.isNullable = false;
  ///         }), unencodedInitialValue: "0");
  void alterColumn(String tableName, String columnName,
      void modify(SchemaColumn targetColumn),
      {String unencodedInitialValue}) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw SchemaException("Table $tableName does not exist.");
    }

    var existingColumn = table[columnName];
    if (existingColumn == null) {
      throw SchemaException("Column $columnName does not exist.");
    }

    var newColumn = SchemaColumn.from(existingColumn);
    modify(newColumn);

    if (existingColumn.type != newColumn.type) {
      throw SchemaException(
          "May not change column type for '${existingColumn.name}' in '$tableName' (${existingColumn.typeString} -> ${newColumn.typeString})");
    }

    if (existingColumn.autoincrement != newColumn.autoincrement) {
      throw SchemaException(
          "May not change column autoincrementing behavior for '${existingColumn.name}' in '$tableName'");
    }

    if (existingColumn.isPrimaryKey != newColumn.isPrimaryKey) {
      throw SchemaException(
          "May not change column primary key status for '${existingColumn.name}' in '$tableName'");
    }

    if (existingColumn.relatedTableName != newColumn.relatedTableName) {
      throw SchemaException(
          "May not change reference table for foreign key column '${existingColumn.name}' in '$tableName' (${existingColumn.relatedTableName} -> ${newColumn.relatedTableName})");
    }

    if (existingColumn.relatedColumnName != newColumn.relatedColumnName) {
      throw SchemaException(
          "May not change reference column for foreign key column '${existingColumn.name}' in '$tableName' (${existingColumn.relatedColumnName} -> ${newColumn.relatedColumnName})");
    }

    if (existingColumn.name != newColumn.name) {
      renameColumn(tableName, existingColumn.name, newColumn.name);
    }

    table.replaceColumn(existingColumn, newColumn);

    final innerCommands = <String>[];
    if (existingColumn.isIndexed != newColumn.isIndexed) {
      if (store != null) {
        if (newColumn.isIndexed) {
          commands.addAll(store.addIndexToColumn(table, newColumn));
        } else {
          commands.addAll(store.deleteIndexFromColumn(table, newColumn));
        }
      } else {
        innerCommands.add("c.isIndexed = ${newColumn.isIndexed}");
      }
    }

    if (existingColumn.isUnique != newColumn.isUnique) {
      if (store != null) {
        commands.addAll(store.alterColumnUniqueness(table, newColumn));
      } else {
        innerCommands.add('c.isUnique = ${newColumn.isUnique}');
      }
    }

    if (existingColumn.defaultValue != newColumn.defaultValue) {
      if (store != null) {
        commands.addAll(store.alterColumnDefaultValue(table, newColumn));
      } else {
        final value = newColumn.defaultValue == null
            ? 'null'
            : '"${newColumn.defaultValue}"';
        innerCommands.add('c.defaultValue = $value');
      }
    }

    if (existingColumn.isNullable != newColumn.isNullable) {
      if (store != null) {
        commands.addAll(store.alterColumnNullability(
            table, newColumn, unencodedInitialValue));
      } else {
        innerCommands.add('c.isNullable = ${newColumn.isNullable}');
      }
    }

    if (existingColumn.deleteRule != newColumn.deleteRule) {
      if (store != null) {
        commands.addAll(store.alterColumnDeleteRule(table, newColumn));
      } else {
        innerCommands.add('c.deleteRule = ${newColumn.deleteRule}');
      }
    }

    if (store == null && innerCommands.isNotEmpty) {
      commands.add("database.alterColumn(\"$tableName\", \"$columnName\", (c) {${innerCommands.join(";")};});");
    }
  }

  void _generateSchemaCommands(SchemaDifference difference,
      {List<String> changeList, bool temporary = false}) {
    // We need to remove foreign keys from the initial table add and defer
    // them until after all tables in the schema have been created.
    // These can occur in both columns and multi column unique.
    // We'll split the creation of those tables into two different sets
    // of commands and run the difference afterwards
    final fkDifferences = <SchemaTableDifference>[];

    difference.tablesToAdd.forEach((t) {
      final copy = SchemaTable.from(t);
      if (copy.hasForeignKeyInUniqueSet) {
        copy.uniqueColumnSet = null;
      }
      copy.columns.where((c) => c.isForeignKey).forEach(copy.removeColumn);

      changeList?.add("Adding table '${copy.name}'");
      createTable(copy);

      fkDifferences.add(SchemaTableDifference(copy, t));
    });

    fkDifferences.forEach((td) {
      _generateTableCommands(td, changeList: changeList);
    });

    difference.tablesToDelete.forEach((t) {
      changeList?.add("Deleting table '${t.name}'");
      deleteTable(t.name);
    });

    difference.tablesToModify.forEach((t) {
      _generateTableCommands(t, changeList: changeList);
    });
  }

  void _generateTableCommands(SchemaTableDifference difference,
      {List<String> changeList}) {
    difference.columnsToAdd.forEach((c) {
      changeList?.add(
          "Adding column '${c.name}' to table '${difference.actualTable.name}'");
      addColumn(difference.actualTable.name, c);

      if (!c.isNullable && c.defaultValue == null) {
        changeList?.add("WARNING: This migration may fail if table '${difference.actualTable.name}' already has rows. "
          "Add an 'unencodedInitialValue' to the statement 'database.addColumn(\"${difference.actualTable.name}\", "
          "SchemaColumn(\"${c.name}\", ...)'.");
      }
    });

    difference.columnsToRemove.forEach((c) {
      changeList?.add(
          "Deleting column '${c.name}' from table '${difference.actualTable.name}'");
      deleteColumn(difference.actualTable.name, c.name);
    });

    difference.columnsToModify.forEach((columnDiff) {
      changeList?.add(
          "Modifying column '${columnDiff.actualColumn.name}' in '${difference.actualTable.name}'");
      alterColumn(difference.actualTable.name, columnDiff.actualColumn.name,
          (c) {
        c.isIndexed = columnDiff.actualColumn.isIndexed;
        c.defaultValue = columnDiff.actualColumn.defaultValue;
        c.isUnique = columnDiff.actualColumn.isUnique;
        c.isNullable = columnDiff.actualColumn.isNullable;
        c.deleteRule = columnDiff.actualColumn.deleteRule;
      });

      if (columnDiff.expectedColumn.isNullable &&
        !columnDiff.actualColumn.isNullable && columnDiff.actualColumn.defaultValue == null) {
        changeList?.add("WARNING: This migration may fail if table '${difference.actualTable.name}' already has rows. "
          "Add an 'unencodedInitialValue' to the statement 'database.addColumn(\"${difference.actualTable.name}\", "
          "SchemaColumn(\"${columnDiff.actualColumn.name}\", ...)'.");
      }
    });

    if (difference.uniqueSetDifference?.hasDifferences ?? false) {
      changeList?.add(
          "Setting unique column constraint of '${difference.actualTable.name}' to ${difference.uniqueSetDifference.actualColumnNames}.");
      alterTable(difference.actualTable.name, (t) {
        if (difference.uniqueSetDifference.actualColumnNames.isEmpty) {
          t.uniqueColumnSet = null;
        } else {
          t.uniqueColumnSet = difference.uniqueSetDifference.actualColumnNames;
        }
      });
    }
  }

  static String _getNewTableExpression(SchemaTable table) {
    var builder = StringBuffer();
    builder.write('database.createTable(SchemaTable("${table.name}", [');
    builder.write(table.columns.map(_getNewColumnExpression).join(","));
    builder.write("]");

    if (table.uniqueColumnSet != null) {
      var set = table.uniqueColumnSet.map((p) => '"$p"').join(",");
      builder.write(", uniqueColumnSetNames: [$set]");
    }

    builder.write('));');
    return builder.toString();
  }

  static String _getNewColumnExpression(SchemaColumn column) {
    var builder = StringBuffer();
    if (column.relatedTableName != null) {
      builder
          .write('SchemaColumn.relationship("${column.name}", ${column.type}');
      builder.write(", relatedTableName: \"${column.relatedTableName}\"");
      builder.write(", relatedColumnName: \"${column.relatedColumnName}\"");
      builder.write(", rule: ${column.deleteRule}");
    } else {
      builder.write('SchemaColumn("${column.name}", ${column.type}');
      if (column.isPrimaryKey) {
        builder.write(", isPrimaryKey: true");
      } else {
        builder.write(", isPrimaryKey: false");
      }
      if (column.autoincrement) {
        builder.write(", autoincrement: true");
      } else {
        builder.write(", autoincrement: false");
      }
      if (column.defaultValue != null) {
        builder.write(', defaultValue: "${column.defaultValue}"');
      }
      if (column.isIndexed) {
        builder.write(", isIndexed: true");
      } else {
        builder.write(", isIndexed: false");
      }
    }

    if (column.isNullable) {
      builder.write(", isNullable: true");
    } else {
      builder.write(", isNullable: false");
    }
    if (column.isUnique) {
      builder.write(", isUnique: true");
    } else {
      builder.write(", isUnique: false");
    }

    builder.write(")");
    return builder.toString();
  }
}
