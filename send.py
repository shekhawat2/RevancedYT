#!/usr/bin/env python3
import os
import sys
from telethon import TelegramClient
from telethon.sessions import StringSession

api_id = os.environ['APPID']
api_hash = os.environ['APIHASH']
session_name = os.environ['SESSIONSTRING']
chat_name = "shekhawat2"

FILE = sys.argv[1]
MSG = sys.argv[2]

with open(MSG,'r') as file:
    message = file.read()

client = TelegramClient(StringSession(session_name), api_id, api_hash)
client.start()
async def main():
    await client.send_file(chat_name, FILE, caption=message, parse_mode='md')

with client:
    client.loop.run_until_complete(main())
