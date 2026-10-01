-- Holds every start of a file for one second before mpv announces it. step3.sh loads this with
-- load-script so that the interval in which IINA reports paused because of the pause a step makes,
-- before the entry stepped to starts, lasts about a second instead of a few milliseconds.
mp.add_hook("on_before_start_file", 50, function(hook)
    hook:defer()
    mp.add_timeout(1, function() hook:cont() end)
end)
