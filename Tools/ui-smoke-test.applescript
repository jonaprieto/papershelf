use scripting additions

property appName : "PaperShelf"

on run
    tell application "PaperShelf" to activate
    tell application "PaperShelf"
        set savedTheme to current theme
        set savedContrast to current PDF contrast
    end tell

    try
        tell application "PaperShelf"
            choose theme "dark"
            choose theme "light"
            choose theme savedTheme
            choose PDF contrast "white on black"
            choose PDF contrast "dark tint"
            choose PDF contrast savedContrast
            show catalogue
            show notes
            toggle inspector
            toggle inspector
            toggle reading mode
            toggle reading mode
            copy current citation
            bookmark current page
            remove current bookmark
            show bookmarks
            open command palette
        end tell

        tell application "System Events"
            tell process "PaperShelf"
                my waitForWindow("All Documents")
                set mainWindow to first window whose name starts with "All Documents"
                my auditToolbar(mainWindow)
                my clickSidebarTwice(mainWindow)
                key code 53
            end tell
        end tell

        tell application "PaperShelf" to show settings
        tell application "System Events"
            tell process "PaperShelf"
                my waitForWindow("General")
                my auditSettings(window "General")
                keystroke "w" using command down
            end tell
        end tell
    on error messageText number errorNumber
        tell application "PaperShelf"
            choose theme savedTheme
            choose PDF contrast savedContrast
        end tell
        error messageText number errorNumber
    end try

    tell application "PaperShelf"
        choose theme savedTheme
        choose PDF contrast savedContrast
    end tell
    return "PaperShelf UI smoke test passed"
end run

on waitForWindow(prefix)
    tell application "System Events"
        tell process "PaperShelf"
            repeat 40 times
                repeat with candidate in windows
                    if (name of contents of candidate as text) starts with prefix then return
                end repeat
                delay 0.1
            end repeat
        end tell
    end tell
    error "Timed out waiting for a PaperShelf window named " & prefix
end waitForWindow

on auditToolbar(theWindow)
    tell application "System Events"
        tell process "PaperShelf"
                set theToolbar to toolbar 1 of theWindow
                repeat with index from 1 to (count of buttons of theToolbar)
                    my assertNamed(button index of theToolbar, "toolbar")
                end repeat
        end tell
    end tell
end auditToolbar

on clickSidebarTwice(theWindow)
    tell application "System Events"
        tell process "PaperShelf"
            set theToolbar to toolbar 1 of theWindow
            set sidebarButton to first button of theToolbar
            if (description of sidebarButton as text) is not "Show Sidebar" and ¬
                (description of sidebarButton as text) is not "Hide Sidebar" then
                error "The first toolbar button is not the sidebar toggle"
            end if
            click sidebarButton
            delay 0.25
            set sidebarButton to first button of toolbar 1 of theWindow
            click sidebarButton
        end tell
    end tell
end clickSidebarTwice

on auditSettings(theWindow)
    tell application "System Events"
        tell process "PaperShelf"
            set controls to buttons of group 1 of scroll area 1 of group 2 of ¬
                splitter group 1 of group 1 of theWindow
            if (count of controls) < 6 then
                error "Settings theme and contrast controls are not all exposed"
            end if
            repeat with index from 1 to 3
                click button index of group 1 of scroll area 1 of group 2 of ¬
                    splitter group 1 of group 1 of theWindow
                delay 0.15
                tell application "PaperShelf" to set actualTheme to current theme
                set expectedTheme to item index of {"System", "Light", "Dark"}
                if actualTheme is not expectedTheme then
                    error "Theme button did not apply its value"
                end if
            end repeat
            repeat with index from 1 to 3
                set controlIndex to index + 3
                click button controlIndex of group 1 of scroll area 1 of group 2 of ¬
                    splitter group 1 of group 1 of theWindow
                delay 0.15
                tell application "PaperShelf" to set actualContrast to current PDF contrast
                set expectedContrast to item index of {"Normal", "Dark tint", "White on black"}
                if actualContrast is not expectedContrast then
                    error "PDF contrast button did not apply its value"
                end if
            end repeat
        end tell
    end tell
end auditSettings

on assertNamed(theButton, area)
    tell application "System Events"
        set labelText to description of theButton as text
        if labelText is "button" or labelText is "" or labelText is "missing value" then
            error "Unnamed " & area & " button"
        end if
    end tell
end assertNamed
