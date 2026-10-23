"""Метаданные экрана в существующей control SQLite. Сеть и медиаключи сюда не входят."""
from contextlib import contextmanager
from pathlib import Path
import sqlite3


class ScreenStore:
    schema_version = 1

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.db() as db:
            if db.execute("SELECT 1 FROM sqlite_master WHERE name='screen_schema'").fetchone():
                version = db.execute('SELECT version FROM screen_schema WHERE singleton=1').fetchone()
                if version is None or version[0] != self.schema_version:
                    raise ValueError('unsupported_screen_schema')
            # Вся additive-миграция атомарна, включая отметку версии. При ошибке
            # откат не оставляет половину схемы и не затрагивает прежние call tables.
            db.executescript(Path(__file__).with_name('screen_schema.sql').read_text())
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            with db:
                yield db
        finally:
            db.close()
