import asyncio
import json
import os
import sys
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        console_messages = []
        page.on("console", lambda msg: console_messages.append(f"[{msg.type}] {msg.text}"))
        page.on("pageerror", lambda err: console_messages.append(f"[PAGE_ERROR] {err}"))

        print("Navigating to http://localhost:8080/#/reader/doc-sample-1 ...")
        await page.goto("http://localhost:8080/#/reader/doc-sample-1", wait_until="networkidle")
        await asyncio.sleep(5)

        screenshot_path = "C:/Users/prave/.gemini/antigravity-ide/brain/b31e076a-40be-4f00-8277-84dccecabbec/clean_editorial_reader.png"
        await page.screenshot(path=screenshot_path)
        print(f"Screenshot captured at: {screenshot_path}")

        print("--- Console Messages ---")
        for msg in console_messages:
            if "error" in msg.lower() or "exception" in msg.lower():
                print(msg)

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
