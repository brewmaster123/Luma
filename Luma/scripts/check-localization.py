#!/usr/bin/env python3
"""0.9.8: checks that the English version leaves nothing in Russian.

1. Every text the interface asks for with tr("...") has an English entry.
2. Every Russian text in the unchanged engine files, as it reaches the screen (after the repair of
   the few strings saved in a broken encoding), has an English entry or is covered by a rule for
   messages with a changing part.
3. The table itself is sound: no entry twice with different English, no Russian left in the English,
   the same number of %@ on both sides, every rule a valid pattern.
4. Texts drawn by the system (the alarm banner, the Watch app) have entries in the .strings files.
5. The app's name is Lumenoir (17 Nov 2026; it was Luma): no English text, no .strings value and
   no name under the icon says Luma; the engine's own texts that still say Luma get a Russian entry
   for the texts iOS draws itself, and both screens replace the old name on the way to the screen.

Reads files only. Run from the Luma folder:  python3 scripts/check-localization.py
"""
import io
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources")
TABLE = os.path.join(SOURCES, "iPhone", "LocalizationTable.swift")
PHONE_FOLDERS = ["LumaCore", "Platform", "iPhone"]

# Files whose Russian literals are the tools of the translation itself, not texts of the app.
TOOL_FILES = {"LocalizationTable.swift", "Localization.swift"}
# Literals that are not shown as they stand.
NOT_SHOWN = {
    "английский",  # the name of English, shown only inside the Russian interface
}

LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
CYRILLIC = re.compile("[Ѐ-ӿ]")
PAIR = re.compile(r'\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)')
UPDATE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"')
RULE = re.compile(r'L10n\.Rule\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"')

problems = []


def read(path):
    with io.open(path, encoding="utf-8") as handle:
        return handle.read().replace("\r\n", "\n")


def unescape(text):
    out, index = [], 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text):
            follower = text[index + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(follower, "\\" + follower))
            index += 2
        else:
            out.append(char)
            index += 1
    return "".join(out)


def repair(text):
    """The same repair as L10n.repair in Localization.swift."""
    def twice(value):
        try:
            fixed = value.encode("cp1251").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return None
        if fixed == value or not fixed:
            return None
        if CYRILLIC.search(fixed) or any(mark in fixed for mark in "·…—–"):
            return fixed
        return None

    if not any(mark in text for mark in ("Р", "С", "В·", "вЂ")):
        return text
    whole = twice(text)
    if whole:
        return whole
    changed, words = False, []
    for word in text.split(" "):
        fixed = twice(word)
        if fixed:
            changed = True
            words.append(fixed)
        else:
            words.append(word)
    return " ".join(words) if changed else text


def strip_comment(line):
    """Cuts a // comment that is not inside a string literal."""
    inside, index = False, 0
    while index < len(line):
        char = line[index]
        if char == "\\" and inside:
            index += 2
            continue
        if char == '"':
            inside = not inside
        elif not inside and line.startswith("//", index):
            return line[:index]
        index += 1
    return line


def interpolations(raw):
    """Splits a literal into its fixed parts; True if it has a changing part."""
    parts, index, current, changing = [], 0, [], False
    while index < len(raw):
        if raw.startswith("\\(", index):
            depth, index = 1, index + 2
            while index < len(raw) and depth:
                depth += {"(": 1, ")": -1}.get(raw[index], 0)
                index += 1
            parts.append("".join(current))
            current, changing = [], True
        else:
            current.append(raw[index])
            index += 1
    parts.append("".join(current))
    return parts, changing


# ---------- the table ----------
table_text = read(TABLE)
sections = table_text.split("static let rules")
body, rules_text = sections[0], sections[1] if len(sections) > 1 else ""
updates_text = body.split("static let table")[0]
pairs_text = body.split("static let table")[1]

updates = {unescape(a): unescape(b) for a, b in UPDATE.findall(updates_text)}
table = {}
for russian, english in PAIR.findall(pairs_text):
    key, value = unescape(russian), unescape(english)
    if key in table and table[key] != value:
        problems.append("two different translations of: %s" % key)
    table.setdefault(key, value)
    if CYRILLIC.search(value):
        problems.append("Russian letters in the English text of: %s" % key)
    if key.count("%@") != value.count("%@"):
        problems.append("different number of %%@ in: %s" % key)
    if key.count("\n") != value.count("\n"):
        problems.append("different number of line breaks in: %s" % key)

rules = []
for pattern, template in RULE.findall(rules_text):
    try:
        rules.append((re.compile(unescape(pattern), re.S), unescape(template)))
    except re.error as error:
        problems.append("rule does not compile: %s (%s)" % (pattern, error))
    if CYRILLIC.search(unescape(template)):
        problems.append("Russian letters in the English text of the rule: %s" % pattern)

for old, new in updates.items():
    if new not in table:
        problems.append("the updated Russian wording has no English: %s" % new)


def covered(text):
    text = updates.get(text, text)
    if text in table:
        return True
    return any(pattern.fullmatch(text) for pattern, _ in rules)


# ---------- the sources ----------
interface_keys, engine_texts = {}, {}
for folder in PHONE_FOLDERS:
    base = os.path.join(SOURCES, folder)
    for name in sorted(os.listdir(base)):
        if not name.endswith(".swift") or name in TOOL_FILES:
            continue
        for number, line in enumerate(read(os.path.join(base, name)).split("\n"), 1):
            code = strip_comment(line)
            for match in LITERAL.finditer(code):
                raw = match.group(1)
                if not CYRILLIC.search(raw):
                    continue
                place = "%s/%s:%d" % (folder, name, number)
                if code[:match.start()].rstrip().endswith("tr("):
                    interface_keys.setdefault(unescape(raw), place)
                else:
                    engine_texts.setdefault(raw, place)

for key, place in sorted(interface_keys.items()):
    if key not in table:
        problems.append("%s: tr() text without English: %s" % (place, key))

for raw, place in sorted(engine_texts.items()):
    parts, changing = interpolations(raw)
    fixed = [repair(unescape(part)) for part in parts]
    if not CYRILLIC.search("".join(fixed)):
        continue
    whole = "".join(fixed)
    if whole in NOT_SHOWN:
        continue
    if not changing:
        # A text used as it is, or the opening of a message that continues with an error text.
        if covered(whole) or (whole.endswith(": ") and covered(whole + "текст ошибки")):
            continue
        problems.append("%s: text without English: %s" % (place, whole))
        continue
    samples = ["7", "текст ошибки", "07:30"]
    if not any(covered(sample.join(fixed)) for sample in samples):
        problems.append("%s: message with a changing part has no rule: %s" % (place, "…".join(fixed)))

# ---------- texts drawn by the system ----------
def strings(*path):
    with open(os.path.join(ROOT, "Resources", "Localization", *path), "rb") as handle:
        return plistlib.load(handle)


phone_strings = strings("iPhone", "en.lproj", "Localizable.strings")
for key in ("Остановить", "Остановить сигнал Luma", "Идентификатор будильника",
            "Непрямой метод · Luma", "Умный будильник · Luma", "Проба AlarmKit · Luma",
            "Подсказка во сне"):
    if key not in phone_strings:
        problems.append("iPhone en.lproj/Localizable.strings has no entry for: %s" % key)
    elif table.get(key) != phone_strings[key]:
        problems.append("iPhone en.lproj and the table disagree on: %s" % key)

watch_strings = strings("Watch", "en.lproj", "Localizable.strings")
watch_folder = os.path.join(SOURCES, "Watch")
for name in sorted(os.listdir(watch_folder)):
    if not name.endswith(".swift") or name == "WatchText.swift":
        continue
    for number, line in enumerate(read(os.path.join(watch_folder, name)).split("\n"), 1):
        code = strip_comment(line)
        for match in LITERAL.finditer(code):
            raw = match.group(1)
            if not CYRILLIC.search(raw):
                continue
            parts, changing = interpolations(raw)
            key = "%@".join(unescape(part) for part in parts)
            place = "Watch/%s:%d" % (name, number)
            # Any of these texts can end up on the watch's own screen (a refusal is also shown as the
            # status there), so each needs an entry in the watch's strings file ...
            if key not in watch_strings and not key.startswith("В очереди на часах: "):
                problems.append("%s: no entry in Watch en.lproj/Localizable.strings: %s" % (place, key))
            # ... and the texts of the watch's schedule store can be sent back to the iPhone, which shows
            # them as "Часы: …"; the iPhone table has to know those too, with the same English.
            if name == "WatchCueStore.swift":
                if not covered(key.replace("%@", "7")):
                    problems.append("%s: text without English in the iPhone table: %s" % (place, key))
                elif key in watch_strings and key in table and table[key] != watch_strings[key]:
                    problems.append("%s: the watch and the iPhone translate this differently: %s" % (place, key))

for bundle in ("iPhone", "Watch"):
    for language in ("en", "ru"):
        for file in os.listdir(os.path.join(ROOT, "Resources", "Localization", bundle, language + ".lproj")):
            values = strings(bundle, language + ".lproj", file)
            for key, value in values.items():
                if language == "en" and CYRILLIC.search(value):
                    problems.append("%s/%s.lproj/%s: Russian letters in: %s" % (bundle, language, file, key))

# ---------- the app's name ----------
# The unchanged engine still says "Luma", so the old name may stay in Russian keys (they mirror the
# engine's literals). Everything a person reads must say Lumenoir.
OLD_NAME = re.compile(r"\bLuma\b")
NEW_NAME = "Lumenoir"
for key, value in table.items():
    if OLD_NAME.search(value):
        problems.append("the English text still says Luma: %s" % value)
for _, template in rules:
    if OLD_NAME.search(template):
        problems.append("a rule's English still says Luma: %s" % template)
for bundle in ("iPhone", "Watch"):
    for language in ("en", "ru"):
        for file in os.listdir(os.path.join(ROOT, "Resources", "Localization", bundle, language + ".lproj")):
            for key, value in strings(bundle, language + ".lproj", file).items():
                if OLD_NAME.search(value):
                    problems.append("%s/%s.lproj/%s still says Luma: %s" % (bundle, language, file, value))
for name in ("iOS", "Watch"):
    with open(os.path.join(ROOT, "Config", name + "-Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleDisplayName") != NEW_NAME:
        problems.append("%s-Info.plist: the name under the icon is not %s" % (name, NEW_NAME))
    for key, value in info.items():
        if isinstance(value, str) and OLD_NAME.search(value):
            problems.append("%s-Info.plist: %s still says Luma" % (name, key))
# Texts iOS and watchOS draw themselves cannot pass through the app: in Russian they need an entry.
SYSTEM_TEXTS = {
    "iPhone": ["Остановить сигнал Luma", "Непрямой метод · Luma", "Умный будильник · Luma",
               "Проба AlarmKit · Luma"],
    "Watch": ["Luma", "Короткий сигнал Luma", "Непрямой метод · Luma", "Умный будильник · Luma",
              "Проба AlarmKit · Luma",
              "Расписание хранится на часах. Для сигнала часы должны быть надеты, разблокированы, "
              "а уведомления Luma разрешены в текущем фокусировании."],
}
for bundle, keys in SYSTEM_TEXTS.items():
    russian = strings(bundle, "ru.lproj", "Localizable.strings")
    english = strings(bundle, "en.lproj", "Localizable.strings")
    for key in keys:
        if russian.get(key) != OLD_NAME.sub(NEW_NAME, key):
            problems.append("%s ru.lproj/Localizable.strings has no Lumenoir entry for: %s" % (bundle, key))
        if key not in english:
            problems.append("%s en.lproj/Localizable.strings has no entry for: %s" % (bundle, key))
for folder, name in (("iPhone", "Localization.swift"), ("Watch", "WatchText.swift")):
    if "static func renamed" not in read(os.path.join(SOURCES, folder, name)):
        problems.append("%s/%s: the old name is not replaced on its way to the screen" % (folder, name))

if problems:
    print("LOCALIZATION CHECK FAILED")
    for problem in problems:
        print(" -", problem)
    sys.exit(1)
print("Localization: %d interface texts, %d engine texts, %d table entries, %d rules — all covered; "
      "the name shown is %s." % (len(interface_keys), len(engine_texts), len(table), len(rules), NEW_NAME))
