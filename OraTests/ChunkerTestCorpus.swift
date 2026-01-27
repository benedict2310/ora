//
//  ChunkerTestCorpus.swift
//  OraTests
//
//  Regression corpus for SentenceChunker.
//

import Foundation

struct ChunkerTestCorpus {

    /// Markdown numbered list (the failing case)
    static let calendarEventList = """
    Here are your events for this week:

    1. **Elfie & Gerhard Skivacay**
       - Calendar: Maddie & Bene
       - Date: January 24-29 (all day)

    2. **PERFORM**
       - Calendar: Maddie & Bene
       - Date: January 25-29 (all day)

    Let me know if you'd like help with anything specific!
    """

    /// Bullet points
    static let bulletList = """
    Here's what you need:
    - Milk
    - Eggs (dozen)
    - Bread
    - Butter
    That should cover breakfast!
    """

    /// No final punctuation
    static let noPunctuation = """
    The answer is 42
    """

    /// Mixed content
    static let mixedContent = """
    Great question! Here are 3 things to remember:
    1. Always save your work
    2. Take breaks every hour
    3. Stay hydrated
    Good luck with your project
    """

    /// Filenames and identifiers (underscores should remain)
    static let filenames = """
    Please open file_name_here.txt and IMG_2024_01_01.png
    Also keep snake_case identifiers intact
    """

    /// Long paragraph requiring split
    static let longParagraph = """
    This is a very long paragraph that exceeds the maximum chunk length and needs to be split at appropriate boundaries such as punctuation marks or whitespace to ensure that each chunk can be processed by the TTS engine without exceeding its token limit while still maintaining natural speech flow and readability for the listener who expects coherent sentences.
    """

    /// Header + code block formatting
    static let headerAndCodeBlock = """
    # Agenda
    Please run:
    ```
    brew install xcodegen
    xcodegen generate
    ```
    Then report back.
    """

    /// Nested list content (list item with bullet details)
    static let nestedList = """
    1. **Launch Prep**
       - Calendar: Maddie & Bene
       - Date: January 24-29 (all day)
       - Location: HQ
    2. **Postmortem**
       - Date: January 30 (10:00-11:00)
    """

    /// Filenames and identifiers mixed with markdown
    static let filenamesWithMarkdown = """
    Please open `file_name_here.txt` and **IMG_2024_01_01.png**
    Keep snake_case identifiers intact.
    """

    /// Calendar week bullets with dates and times
    static let calendarWeekBullets = """
    Here are your events for this week:

    - Monday, January 25: All day - "Elfie & Gerhard Skivacay" (in calendar 'Maddie & Bene')
    - Tuesday, January 26: All day - "PERFORM" (in calendar 'Maddie & Bene')
    - Wednesday, January 27: All day - "Raphael Faisthuber*" (in calendar 'Familie')
    - Wednesday, January 27: 10:15-11:15 - "Pilates mums & babies!" (in calendar 'Maddie & Bene')
    - Thursday, January 28: 12:15-13:15 - "Magda physio 12:15" (in calendar 'Maddie & Bene')
    - Thursday, January 28: 14:00-15:00 - "Sophia Spatt 14:00" (in calendar 'Maddie & Bene')
    - Friday, January 29: 12:15-13:45 - "Maddie facial 12:30" (in calendar 'Maddie & Bene')
    - Friday, January 30: 13:00-14:00 - "Elektriker home visit" (in calendar 'Maddie & Bene')
    - Friday, January 30: 15:00-19:00 - "Evi & Peter" (at Kochstrasse 10, Attnang-Puchheim, Austria)
    - Sunday, January 30: All day - "Thomas Hechenberger's 46th Birthday" (in calendar 'Birthdays')
    - Sunday, February 2: All day - "Diphtheria tetanus Impfung (2/2)" and "Pneumococcus Impfung" (in calendar 'Sophia Reminders')

    Let me know if you'd like help with anything specific!
    """
}
