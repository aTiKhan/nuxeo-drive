import os

import pytest

# from nxdrive import __version__
from nxdrive.exceptions import NoAssociatedSoftware

from ..markers import windows_only

# import sqlite3


# from nxdrive.manager import Manager
# from nxdrive.options import Options


@windows_only
def test_open_local_file_no_soft(manager_factory, monkeypatch):
    """
    Ensure that manager.open_local_file() raises our exception
    when there is no associated software.
    """

    def startfile(path):
        raise OSError(
            1155,
            "No application is associated with the specified file for this operation.",
            path,
            1155,
        )

    monkeypatch.setattr(os, "startfile", startfile)
    with manager_factory(with_engine=False) as manager, pytest.raises(
        NoAssociatedSoftware
    ):
        manager.open_local_file("File.azerty")


# @Options.mock()
# def test_manager_init_failed_migrations(tmp_path, monkeypatch):
#     """
#     Ensure that when the migrations fail, the xxx_broken_update option is saved.
#     """
#     from nxdrive.dao.migrations.manager import manager_migrations as orignal_migrations

#     assert Options.xxx_broken_update is None
#     assert Options.feature_auto_update

#     class MockedMigration:
#         """Mocked migration that raise an exception on upgrade."""

#         def upgrade(self, _):
#             raise sqlite3.Error("Mocked exception")

#     # Init the database with the initial migration
#     with Manager(tmp_path):
#         pass

#     new_migrations = orignal_migrations.copy()
#     new_migrations["9999_test"] = MockedMigration()

#     with pytest.raises(SystemExit):
#         monkeypatch.setattr(
#             "nxdrive.dao.migrations.manager.manager_migrations",
#             new_migrations,
#         )

#         try:
#             # Run the new failing migration
#             with Manager(tmp_path):
#                 pass
#         finally:
#             monkeypatch.undo()

#     assert Options.xxx_broken_update == __version__
#     assert not Options.feature_auto_update
