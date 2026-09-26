--[[ SquizzFrames SnapGrid

    Edit Mode's alignment grid and snapping, via LibSquizzGrid-1.0 (Libs/),
    which Squizzumables embeds too -- one grid and one toolbar whichever of the
    two addons is in its move mode, and frames of either can snap to the
    other's. See the library's header for what it draws and snaps to.

    This file only connects SquizzFrames to it:
      * settings live at SquizzFramesDB.snapGrid -- account-wide, like the
        other SV-root keys (lastSeenVersion, nicknames): it is a preference
        about how you lay things out, not part of a layout
      * the grid and toolbar follow "EditModeChanged"
      * SquizzFrames.SnapTarget(frame) / SnapDelta(frame) / SnapClear() are
        what the movers call. All three are no-ops without the library, so a
        mover never has to check for it.

    Every mover snaps the SAME way: place the frame where the cursor puts it,
    ask SnapDelta how far it is from the nearest target (UIParent units), and
    add that to the drag offset. Every saved offset here is already in
    UIParent units, so the delta adds straight on whatever the anchor scheme --
    which is why the party container's configurable anchor point needs no
    special case.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end
local F = SquizzFrames.F

local Grid = LibStub and LibStub("LibSquizzGrid-1.0", true)

function SquizzFrames.SnapTarget(frame)
    if Grid and frame then Grid:RegisterTarget(frame) end
end

function SquizzFrames.SnapDelta(frame)
    if not Grid then return 0, 0 end
    return Grid:SnapFrameDelta(frame)
end

function SquizzFrames.SnapClear()
    if Grid then Grid:ClearGuides() end
end

if not Grid then return end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    SquizzFramesDB = SquizzFramesDB or {}
    SquizzFramesDB.snapGrid = SquizzFramesDB.snapGrid or {}
    Grid:SetStorage(SquizzFramesDB.snapGrid)
    -- A reload while in Edit Mode: nothing re-fires the message.
    if SquizzFrames.editMode then Grid:Activate("SquizzFrames") end
end)

-- Its own message owner: CallbackHandler keeps one handler per
-- (owner, message), so registering on the addon root could silently replace
-- another module's EditModeChanged handler (see CLAUDE.md).
if F and F.NewMessageOwner then
    F.NewMessageOwner():RegisterMessage("EditModeChanged", function(_, enabled)
        if enabled then Grid:Activate("SquizzFrames") else Grid:Deactivate("SquizzFrames") end
    end)
end
