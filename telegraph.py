#!/usr/bin/env python3
# Download telegraph images from URL
#
# This software is licensed under BSD Zero Clause OR CC0 v1.0 Universal OR
# WTFPL Version 2. You may choose any of them at your will.
#
# The software is provided "as is" and the author disclaims all warranties with
# regard to this software including all implied warranties of merchantability
# and fitness. In no event shall the author be liable for any special, direct,
# indirect, or consequential damages or any damages whatsoever resulting from
# loss of use, data or profits, whether in an action of contract, negligence or
# other tortious action, arising out of or in connection with the use or
# performance of this software.

import os.path
import random
import re
import sys
import time
from typing import Dict, List
from urllib import parse

import requests

user_agent = [
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.1 (KHTML, like Gecko) Chrome/22.0.1207.1 Safari/537.1",
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/536.6 (KHTML, like Gecko) Chrome/20.0.1092.0 Safari/536.6",
    "Mozilla/5.0 (Windows NT 6.2) AppleWebKit/536.6 (KHTML, like Gecko) Chrome/20.0.1090.0 Safari/536.6",
    "Mozilla/5.0 (Windows NT 6.2; WOW64) AppleWebKit/537.1 (KHTML, like Gecko) Chrome/19.77.34.5 Safari/537.1",
    "Mozilla/5.0 (Windows NT 6.0) AppleWebKit/536.5 (KHTML, like Gecko) Chrome/19.0.1084.36 Safari/536.5",
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1063.0 Safari/536.3",
    "Mozilla/5.0 (Windows NT 5.1) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1063.0 Safari/536.3",
    "Mozilla/5.0 (Windows NT 6.2) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1062.0 Safari/536.3",
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1062.0 Safari/536.3",
    "Mozilla/5.0 (Windows NT 6.2) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1061.1 Safari/536.3",
    "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1061.1 Safari/536.3",
    "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1061.1 Safari/536.3",
    "Mozilla/5.0 (Windows NT 6.2) AppleWebKit/536.3 (KHTML, like Gecko) Chrome/19.0.1061.0 Safari/536.3",
    "Mozilla/5.0 (Windows NT 6.2; WOW64) AppleWebKit/535.24 (KHTML, like Gecko) Chrome/19.0.1055.1 Safari/535.24",
]


def headers() -> Dict[str, str]:
    return {"User-Agent": random.choice(user_agent), "Referer": "https://telegra.ph/"}


def get_url(url: str, session: requests.Session) -> str:
    return session.get(url=url, headers=headers()).text


def extract_image_url(html: str) -> List[str]:
    return re.findall(r'img src="(\S+)"', html)


def image_url_to_info(url: str) -> Dict[str, str]:
    name = url.replace("/file/", "")
    url = "https://telegra.ph" + url
    return {"name": name, "url": url}


def get_image_content(url: str, session: requests.Session) -> bytes:
    return session.get(url=url, headers=headers()).content


def get_url_images(url: str, session: requests.Session) -> List[Dict[str, str]]:
    return [image_url_to_info(i) for i in extract_image_url(get_url(url, session))]


def download(
    output_path: str, external_id: str, url: str, session: requests.Session
) -> None:
    path = re.findall(r"telegra.ph/(.+)", parse.unquote(url))[0]
    info = get_url_images(url, session)

    for i in info:
        name = i["name"]
        url = i["url"]
        filename = external_id + "_" + path + "_" + name
        filename = "".join(
            c for c in filename if c.isalpha() or c.isdigit() or c == " "
        ).rstrip()
        filename = output_path + "/" + filename
        if not os.path.exists(filename):
            with open(filename, "wb") as f:
                f.write(get_image_content(url, session))
            print(f"Downloaded {filename}")
            time.sleep(1)
        else:
            print(f"Skipping {filename}")


if __name__ == "__main__":
    download(sys.argv[1], sys.argv[2], sys.argv[3], requests.session())
