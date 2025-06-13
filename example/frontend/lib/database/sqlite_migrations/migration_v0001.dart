// GENERATED CODE - DO NOT MODIFY BY HAND
// Migration version: 1
// Generated on 2025-06-12 21:37:49.892965

const List<String> migrationSqlStatementsV1 = [
  '''-- Initial Schema (Version 1)''',
  '''-- Generated on 2025-06-12 21:37:49.887464''',
  r'''
CREATE TABLE IF NOT EXISTS "bookstores" (
  "address" TEXT,
  "created_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "established_date" TEXT,
  "id" TEXT NOT NULL,
  "is_open" INTEGER DEFAULT 1,
  "name" TEXT NOT NULL,
  "updated_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("id")
);
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_bookstores_name" ON "bookstores" ("name");
''',
  r'''
CREATE TABLE IF NOT EXISTS "authors" (
  "bio" TEXT,
  "birth_date" TEXT,
  "created_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "death_date" TEXT,
  "document" TEXT,
  "first_name" TEXT NOT NULL,
  "id" TEXT NOT NULL,
  "last_name" TEXT NOT NULL,
  "updated_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("id")
);
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_authors_full_text_search" ON "authors" ("document");
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_authors_last_name" ON "authors" ("last_name");
''',
  r'''
CREATE TABLE IF NOT EXISTS "genres" (
  "created_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "description" TEXT,
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL UNIQUE,
  "updated_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("id")
);
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_genres_name" ON "genres" ("name");
''',
  r'''
CREATE TABLE IF NOT EXISTS "images" (
  "alt_text" TEXT,
  "created_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "id" TEXT NOT NULL,
  "updated_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "url" TEXT NOT NULL,
  PRIMARY KEY ("id")
);
''',
  r'''
CREATE TABLE IF NOT EXISTS "books" (
  "author_id" TEXT,
  "banner_image_id" TEXT,
  "cover_image_id" TEXT,
  "created_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "description" TEXT,
  "document" TEXT,
  "id" TEXT NOT NULL,
  "metadata" TEXT,
  "price" REAL,
  "publication_date" TEXT,
  "stock_count" INTEGER DEFAULT 0,
  "tags" TEXT,
  "title" TEXT NOT NULL,
  "updated_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("id"),
  CONSTRAINT "books_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "authors" ("id") ON DELETE SET NULL ON UPDATE NO ACTION,
  CONSTRAINT "books_banner_image_id_fkey" FOREIGN KEY ("banner_image_id") REFERENCES "images" ("id") ON DELETE SET NULL ON UPDATE NO ACTION,
  CONSTRAINT "books_cover_image_id_fkey" FOREIGN KEY ("cover_image_id") REFERENCES "images" ("id") ON DELETE SET NULL ON UPDATE NO ACTION
);
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_books_full_text_search" ON "books" ("document");
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_books_publication_date" ON "books" ("publication_date");
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_books_title" ON "books" ("title");
''',
  r'''
CREATE TABLE IF NOT EXISTS "book_genres" (
  "book_id" TEXT,
  "genre_id" TEXT,
  "id" INTEGER PRIMARY KEY NOT NULL,
  CONSTRAINT "book_genres_book_id_fkey" FOREIGN KEY ("book_id") REFERENCES "books" ("id") ON DELETE CASCADE ON UPDATE NO ACTION,
  CONSTRAINT "book_genres_genre_id_fkey" FOREIGN KEY ("genre_id") REFERENCES "genres" ("id") ON DELETE CASCADE ON UPDATE NO ACTION,
  CONSTRAINT "book_genres_book_id_genre_id_key_unique" UNIQUE ("book_id", "genre_id")
);
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_book_genres_book_id" ON "book_genres" ("book_id");
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_book_genres_genre_id" ON "book_genres" ("genre_id");
''',
  r'''
CREATE TABLE IF NOT EXISTS "bookstore_books" (
  "book_id" TEXT,
  "bookstore_id" TEXT,
  "id" INTEGER PRIMARY KEY NOT NULL,
  CONSTRAINT "bookstore_books_book_id_fkey" FOREIGN KEY ("book_id") REFERENCES "books" ("id") ON DELETE CASCADE ON UPDATE NO ACTION,
  CONSTRAINT "bookstore_books_bookstore_id_fkey" FOREIGN KEY ("bookstore_id") REFERENCES "bookstores" ("id") ON DELETE CASCADE ON UPDATE NO ACTION,
  CONSTRAINT "bookstore_books_bookstore_id_book_id_key_unique" UNIQUE ("bookstore_id", "book_id")
);
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_bookstore_books_book_id" ON "bookstore_books" ("book_id");
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_bookstore_books_bookstore_id" ON "bookstore_books" ("bookstore_id");
''',
  r'''
CREATE TABLE IF NOT EXISTS "profiles" (
  "avatar_url" TEXT,
  "created_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "full_name" TEXT,
  "id" TEXT NOT NULL,
  "updated_at" TEXT DEFAULT CURRENT_TIMESTAMP,
  "username" TEXT UNIQUE,
  "website" TEXT,
  PRIMARY KEY ("id"),
  CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "users" ("id") ON DELETE CASCADE ON UPDATE NO ACTION
);
''',
  r'''
CREATE INDEX IF NOT EXISTS "idx_profiles_username" ON "profiles" ("username");
''',
];
