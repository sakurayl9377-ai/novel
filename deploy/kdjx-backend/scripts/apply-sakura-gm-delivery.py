#!/usr/bin/env python3
"""Install the fail-closed Sakura GM mail bridge into a KDJX source tree."""

from __future__ import print_function

import argparse
import shutil
import sys
from pathlib import Path


SERVER_ANCHOR = "\ts.initSakuraPayments()\n"
SERVER_CALL = "\ts.initSakuraGMDelivery()\n"
GAME_SERVICE_CONSTRUCTOR_ANCHOR = (
    "func NewService(option service.IOption, container service.IContainer) service.IService {\n"
)
GAME_SERVICE_REGISTER_ANCHOR = '\ts.Register(s, "GetOpenDays")\n'
GAME_SERVICE_REGISTER = '\ts.Register(s, "SakuraGMSendMail")\n'
GAME_SERVICE_METHOD = r'''
func (s *Service) SakuraGMSendMail(inlPwd string, requestID string, roleID document.ID, mailType int, sender string, subject string, content string, attachs map[document.Integer]int, reconcileOnly bool) (response string, err error) {
	return
}

'''
RPC_ANCHOR = "\t@rpc_coroutine\n\tdef gmSendMail(self, roleID, mailType, sender, subject, content, attachs):\n"
RPC_METHOD = r'''
	@rpc_coroutine
	def SakuraGMSendMail(self, inl_pwd, requestID, roleID, mailType, sender, subject, content, attachs, reconcileOnly):
		if inl_pwd != GameServInternalPassword:
			raise Return('auth_error')
		if not requestID or len(requestID) > 64:
			raise Return('request_invalid')
		roleID = yield self._prepareRoleID(roleID)
		import copy
		from game.object.game import ObjectGame
		from game.object.game.role import ObjectRole
		from game.object.game.gain import pack
		from game.handler.inl_mail import sendMail

		# ID 400 is the client's virtual display item for trainer/role EXP.
		# Deliver it as role_exp so claiming the mail updates level progress.
		if 400 in attachs:
			attachs = dict(attachs)
			trainerExp = attachs.pop(400)
			attachs['role_exp'] = attachs.get('role_exp', 0) + trainerExp

		expectedAttachs = pack(attachs)
		query = {'role_db_id': roleID, 'content': content}

		def matchesRequest(mail):
			return (
				mail.get('role_db_id') == roleID and
				mail.get('type') == mailType and
				mail.get('sender') == sender and
				mail.get('subject') == subject and
				mail.get('content') == content and
				mail.get('attachs') == expectedAttachs
			)

		@coroutine
		def ensureVisible(mail):
			mailID = mail['id']
			game = ObjectGame.getByRoleID(roleID, safe=False)
			if game and game.is_gc_destroy():
				game = None
			if game:
				if mailID not in game.role.getMailIDs():
					game.role.addMailThumb(
						mailID,
						mail['subject'],
						mail['time'],
						mail['type'],
						mail['sender'],
						False,
						mail['attachs'] and True or False,
					)
					game.role.setMailModel(mailID, mail)
				mailbox = copy.deepcopy(game.role.mailbox)
			else:
				roleData = yield self.dbcGame.call_async(
					'DBMultipleReadKeys', 'Role', [roleID], ['mailbox'])
				if not roleData['ret'] or len(roleData.get('models', [])) != 1:
					raise Return(False)
				mailbox = roleData['models'][0].get('mailbox') or []
				if not any(info.get('db_id') == mailID for info in mailbox):
					mailbox = ObjectRole.addMailThumbInMem(
						mailbox, mail, roleID)

			# An online role's watched mailbox is eventually persisted by the
			# game queue, but delivery acknowledgement must not depend on that
			# delayed flush. Persist and verify the exact active snapshot now.
			updated = yield self.dbcGame.call_async(
				'DBUpdate', 'Role', roleID, {'mailbox': mailbox}, False)
			if not updated['ret']:
				raise Return(False)
			verified = yield self.dbcGame.call_async(
				'DBMultipleReadKeys', 'Role', [roleID], ['mailbox'])
			if not verified['ret'] or len(verified.get('models', [])) != 1:
				raise Return(False)
			verifiedMailbox = verified['models'][0].get('mailbox') or []
			raise Return(any(
				info.get('db_id') == mailID for info in verifiedMailbox))

		try:
			existing = yield self.dbcGame.call_async('DBReadBy', 'Mail', query)
		except Exception:
			logger.exception('SakuraGMSendMail lookup error request %s', requestID)
			raise Return('delivery_outcome_unknown')
		if not existing['ret']:
			raise Return('delivery_outcome_unknown')
		existingModels = existing.get('models', [])
		if len(existingModels) > 1:
			raise Return('delivery_outcome_unknown')
		if len(existingModels) == 1:
			existingMail = existingModels[0]
			if not matchesRequest(existingMail):
				raise Return('request_conflict')
			if not existingMail.get('deleted_flag', False):
				try:
					visible = yield ensureVisible(existingMail)
				except Exception:
					logger.exception(
						'SakuraGMSendMail repair error request %s', requestID)
					raise Return('delivery_outcome_unknown')
				if not visible:
					raise Return('delivery_outcome_unknown')
			raise Return('existing:' + objectid2string(existingMail['id']))

		# A timed-out caller may only reconcile the original request. It must
		# never create a second mail while the first RPC is still completing.
		if reconcileOnly:
			raise Return('delivery_pending')

		mail = ObjectRole.makeMailModel(roleID, mailType, sender, subject, content, attachs)
		try:
			sent = yield sendMail(mail, self.dbcGame, ObjectGame.getByRoleID(roleID, safe=False))
		except Exception:
			logger.exception('SakuraGMSendMail error request %s', requestID)
			raise Return('delivery_outcome_unknown')
		if not sent:
			raise Return('delivery_rejected')
		try:
			created = yield self.dbcGame.call_async('DBReadBy', 'Mail', query)
		except Exception:
			logger.exception('SakuraGMSendMail reconcile error request %s', requestID)
			raise Return('delivery_outcome_unknown')
		if not created['ret'] or len(created.get('models', [])) != 1:
			raise Return('delivery_outcome_unknown')
		createdMail = created['models'][0]
		if not matchesRequest(createdMail):
			raise Return('delivery_outcome_unknown')
		try:
			visible = yield ensureVisible(createdMail)
		except Exception:
			logger.exception('SakuraGMSendMail verify error request %s', requestID)
			raise Return('delivery_outcome_unknown')
		if not visible:
			raise Return('delivery_outcome_unknown')
		mailID = createdMail['id']
		raise Return('ok:' + objectid2string(mailID))

'''


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def copy_tree(source, destination):
    if not source.is_dir() or source.is_symlink():
        fail("Sakura GM Go patch directory is missing or invalid")
    if destination.exists():
        shutil.rmtree(str(destination))
    shutil.copytree(str(source), str(destination))


def patch_once(path, anchor, addition, label):
    content = path.read_text(encoding="utf-8")
    if addition in content:
        return
    if content.count(anchor) != 1:
        fail("{} source does not match the supported layout".format(label))
    path.write_text(content.replace(anchor, anchor + addition, 1), encoding="utf-8")


def patch_before_once(path, anchor, addition, label):
    content = path.read_text(encoding="utf-8")
    if addition in content:
        return
    if content.count(anchor) != 1:
        fail("{} source does not match the supported layout".format(label))
    path.write_text(content.replace(anchor, addition + anchor, 1), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--patch-root", required=True)
    args = parser.parse_args()
    root = Path(args.source_root).resolve()
    patch_root = Path(args.patch_root).resolve()
    login_root = root / "gosrc" / "tjgame" / "login"
    server = login_root / "server.go"
    game_service = root / "gosrc" / "tjgame" / "services" / "game" / "service.go"
    rpc = root / "release" / "src" / "game" / "rpc.py"
    for path in (server, game_service, rpc):
        if not path.is_file():
            fail("required KDJX source is missing: {}".format(path))
    go_patch = patch_root / "sakura_gm.go"
    if not go_patch.is_file() or go_patch.is_symlink():
        fail("Sakura GM Go bridge patch is missing or invalid")

    copy_tree(patch_root / "sakuragm", login_root / "sakuragm")
    shutil.copy2(str(go_patch), str(login_root / "sakura_gm.go"))
    patch_once(server, SERVER_ANCHOR, SERVER_CALL, "login server")
    # Remote Go services are fail-closed: CallWithTimeout refuses any method
    # absent from the static services/game stub before an NSQ request is sent.
    # Keep the metadata-only method signature aligned with the Python RPC and
    # register it in NewService so the login bridge can actually dispatch it.
    patch_before_once(
        game_service,
        GAME_SERVICE_CONSTRUCTOR_ANCHOR,
        GAME_SERVICE_METHOD,
        "game service RPC stub",
    )
    patch_once(
        game_service,
        GAME_SERVICE_REGISTER_ANCHOR,
        GAME_SERVICE_REGISTER,
        "game service RPC registration",
    )
    # RPC_ANCHOR includes gmSendMail's decorator and function declaration.
    # Inserting after it detaches the existing function body and leaves an
    # empty method, which Python rejects when it reaches our next decorator.
    # Install the Sakura method before the complete declaration so both
    # methods remain siblings in the containing RPC class.
    patch_before_once(rpc, RPC_ANCHOR, RPC_METHOD, "game RPC")

    if server.read_text(encoding="utf-8").count(SERVER_CALL) != 1:
        fail("Sakura GM login registration is incomplete")
    game_service_content = game_service.read_text(encoding="utf-8")
    if (
        game_service_content.count("func (s *Service) SakuraGMSendMail(") != 1
        or game_service_content.count(GAME_SERVICE_REGISTER) != 1
        or game_service_content.index("func (s *Service) SakuraGMSendMail(")
        > game_service_content.index(GAME_SERVICE_CONSTRUCTOR_ANCHOR)
    ):
        fail("Sakura GM game service RPC registration is incomplete")
    rpc_content = rpc.read_text(encoding="utf-8")
    if (
        rpc_content.count("def SakuraGMSendMail(") != 1
        or "GameServInternalPassword" not in rpc_content
        or "'DBReadBy', 'Mail'" not in rpc_content
        or "def ensureVisible(mail):" not in rpc_content
        or "def matchesRequest(mail):" not in rpc_content
        or "if reconcileOnly:" not in rpc_content
        or "raise Return('delivery_pending')" not in rpc_content
        or "\t\timport copy\n" not in rpc_content
        or "attachs['role_exp']" not in rpc_content
        or "raise Return('request_conflict')" not in rpc_content
    ):
        fail("Sakura GM game RPC is incomplete")


if __name__ == "__main__":
    main()
