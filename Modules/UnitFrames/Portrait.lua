--[[ SquizzFrames UnitFrames Portrait (Phase 2)

    Three portrait styles for the standalone unit frames:

      "2d"     the flat portrait texture, via SetPortraitTexture
      "3d"     a live PlayerModel showing the unit's actual model
      "class"  the class icon from the shared class-icon sheet

    The class style is the one with teeth. CLASS_ICON_TCOORDS is indexed BY
    CLASS FILE, and UnitClass's classFile return is secret when the unit's
    identity is restricted -- indexing a table with a secret key hard-errors.
    F.IsValueNonSecret gates it, exactly as F.GetClassColor does for
    RAID_CLASS_COLORS. `type(classFile) == "string"` is NOT a substitute: a
    secret string still reports "string". That mistake has already been made
    once in this module (see UnitFrames.lua's ResolveHealthColor).

    3D portraits are a PlayerModel, which is comparatively expensive and can
    fail to resolve a model for a unit that is not currently visible to the
    client. SetUnit is re-applied on UNIT_MODEL_CHANGED and whenever the token
    is reassigned, and the model falls back to hidden rather than showing a
    stale one.
]]

local SquizzFrames = _G["SquizzFrames"]
local F = SquizzFrames and SquizzFrames.F
if not SquizzFrames then return end

local Portrait = {}
SquizzFrames.UnitFramePortrait = Portrait

-- Built once per unit frame. Both the texture and the model frame exist from
-- the start and are shown/hidden per style, rather than being created lazily:
-- switching style mid-combat would otherwise mean creating a frame then.
function Portrait.Create(parent, unit)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetFrameStrata(parent:GetFrameStrata() or "MEDIUM")
    holder:SetFrameLevel((parent:GetFrameLevel() or 1) + 3)
    -- Real size from the outset. ApplySettings resizes it properly later, but
    -- a PlayerModel created inside a 0x0 parent can fail to initialise its
    -- viewport and then never render anything, whatever you set on it
    -- afterwards. Cheap insurance against a whole class of "the model is
    -- configured correctly and still blank".
    holder:SetSize(40, 40)
    holder:Hide()

    local tex = holder:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(holder)
    holder.texture = tex

    local model = CreateFrame("PlayerModel", nil, holder)
    model:SetAllPoints(holder)
    -- SetCamera(0) is REQUIRED for anything to render here. Removing it (on
    -- the theory that it was what broke creature models) made every 3D
    -- portrait blank, players included -- so it goes back.
    if model.SetCamera then model:SetCamera(0) end
    model:Hide()
    holder.model = model

    -- ModelScene WAS TRIED AND DOES NOT WORK. Do not spend another evening on
    -- it. Built 2026-09-05 as a selectable style, tested against a live mob,
    -- and it rendered nothing exactly as PlayerModel does:
    --
    --   * ModelScene actor + ModelSceneMixin + AcquireActor +
    --     actor:SetModelByUnit(unit) -- blank, same as PlayerModel:SetUnit.
    --     Its docs carry the same RequiresDeclassifiedUnitIdentity gate, so
    --     that is almost certainly the shared cause rather than a coincidence.
    --   * actor:SetModelByCreatureDisplayID carries NO identity requirement
    --     and would sidestep the gate -- but nothing public exposes a live
    --     unit's creature display ID. Both APIs that take one only CONSUME it.
    --
    -- If a future patch exposes a unit->displayID lookup, that is the one
    -- avenue left open. Until then 3D is players-only with a 2D fallback.
    local border = holder:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints(holder)
    border:SetColorTexture(0, 0, 0, 0)
    holder.border = border

    holder._sfUnit = unit
    return holder
end

-- Size and place the holder. Returns the horizontal inset the frame's own text
-- should give it, which is 0 unless the portrait sits INSIDE the frame -- an
-- outside portrait costs the frame's contents nothing.
function Portrait.ApplySettings(holder, parent, t)
    if not holder or not parent or not t then return 0 end
    local cfg = t.portrait
    if not cfg or not cfg.enabled then
        holder:Hide()
        return 0
    end

    local h = t.height or 46
    local size = (cfg.size and cfg.size > 0) and cfg.size or h
    holder:SetSize(size, size)
    holder:ClearAllPoints()

    local side = cfg.side or "LEFT"
    local ox, oy = cfg.offsetX or 0, cfg.offsetY or 0
    if cfg.inside then
        -- Overlaps the health bar. The frame keeps its configured width, so
        -- the portrait eats into the space available for text rather than
        -- making the frame wider.
        holder:SetPoint(side, parent, side, (side == "LEFT" and ox or -ox), oy)
    else
        -- Sits beside the frame. Anchored to the OPPOSITE point so the two
        -- sit flush against each other.
        local opposite = (side == "LEFT") and "RIGHT" or "LEFT"
        holder:SetPoint(opposite, parent, side, (side == "LEFT" and -ox - 2 or ox + 2), oy)
    end

    local b = cfg.borderColor
    if b then
        holder.border:SetColorTexture(b[1] or 0, b[2] or 0, b[3] or 0, b[4] or 0)
    end

    holder:Show()
    return cfg.inside and (size + 2) or 0
end

-- Add or remove the circular mask on the 2D texture.
--
-- The mask is created lazily and then kept: MaskTexture objects cannot be
-- destroyed, so creating one per style change would leak. Removing the mask is
-- what makes the portrait square again -- clearing texcoords does not, because
-- the roundness comes from the mask's alpha, not from the crop.
local function ApplyMask(holder, wantMask)
    if wantMask then
        if not holder._sfMask then
            local mask = holder:CreateMaskTexture()
            mask:SetAllPoints(holder.texture)
            mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            holder._sfMask = mask
        end
        if not holder._sfMaskOn then
            holder.texture:AddMaskTexture(holder._sfMask)
            holder._sfMaskOn = true
        end
    elseif holder._sfMaskOn then
        holder.texture:RemoveMaskTexture(holder._sfMask)
        holder._sfMaskOn = false
    end
end

-- Fill the portrait for the unit currently behind the token.
function Portrait.Update(holder, unit, t)
    if not holder then return end
    local cfg = t and t.portrait
    if not cfg or not cfg.enabled then
        holder:Hide()
        return
    end
    if not unit or not UnitExists(unit) then
        -- Blank rather than leaving the previous unit's face on screen.
        holder.model:Hide()
        holder.texture:SetTexture(nil)
        return
    end


    local style = cfg.style or "2d"
    local square = (cfg.shape or "square") == "square"

    -- 3D FALLS BACK TO 2D WHENEVER THE MODEL WILL NOT LOAD.
    --
    -- WHY it will not load, from Blizzard's own generated API docs
    -- (FrameAPICharacterModelBaseDocumentation.lua on the 12.1 branch):
    --
    --     Name = "SetUnit",
    --     RequiresDeclassifiedUnitIdentity = true,
    --     Returns = { { Name = "success", Type = "bool" } },
    --
    -- SetUnit now REQUIRES the unit's identity to be declassified. Where 12.1
    -- keeps identity secret -- instanced content above all, which is where
    -- this was first seen (a Delve) -- it simply refuses. That is why a naga
    -- mob rendered as empty space while a player beside it was fine, and why
    -- EllesmereUI fails identically on the same target: nothing about the call
    -- sequence was ever the problem.
    --
    -- BUT THE success RETURN IS NOT A SUFFICIENT DETECTOR, tested: for a
    -- creature model SetUnit reports success and still renders nothing. A
    -- version keyed purely off that return therefore never fell back, and mobs
    -- went from a working 2D portrait to an empty box.
    --
    -- So the gate is UnitIsPlayer, which matches what is actually observed,
    -- with the success check kept underneath it as a second net for a player
    -- whose identity is classified (rated PvP, some instanced content) where
    -- SetUnit does genuinely refuse.
    --
    -- Observation wins over the documentation here. The docs describe a
    -- precondition; they do not promise the return value reports every way the
    -- call can come to nothing.
    if style == "3d" and not UnitIsPlayer(unit) then
        style = "2d"
    end


    if style == "3d" then
        holder.texture:Hide()
        holder.model:Show()
        local m = holder.model

        -- Camera properties are set before SetUnit (oUF's order) simply
        -- because SetUnit applies whatever camera state exists at load time.
        -- Do NOT read more into it than that: reordering these calls does not
        -- make creature models render, which is why non-players never reach
        -- this branch at all. Only the availability gate below and SetCamera(0)
        -- at creation are load-bearing.
        --
        -- IsUnitModelReadyForUI catches a model that has not streamed yet.
        -- Calling SetUnit on one leaves a permanently blank widget with
        -- nothing to retrigger it, so we drop to 2D and let
        -- UNIT_MODEL_CHANGED / PORTRAITS_UPDATED bring us back.
        local available = m:IsVisible()
            and (not IsUnitModelReadyForUI or IsUnitModelReadyForUI(unit))
            and UnitIsConnected(unit) and UnitIsVisible(unit)

        local rendered = false
        if available then
            m:ClearModel()
            m:SetCamDistanceScale(cfg.zoom or 1)
            m:SetPortraitZoom(1)
            m:SetPosition(0, 0, 0)
            -- pcall'd as well as return-checked: the docs state a PRECONDITION
            -- (declassified identity) rather than describing what happens when
            -- it is violated, so treat a thrown error and a false return as
            -- the same answer. `nil` counts as success so a client that
            -- returns nothing keeps working.
            local ok, success = pcall(m.SetUnit, m, unit)
            rendered = ok and success ~= false
        end
        if rendered then return end

        -- Could not load. Drop to 2D rather than leaving the widget up: a
        -- PlayerModel holding nothing falls back to showing the PLAYER, which
        -- is what originally put your own face on the target frame.
        m:ClearModel()
        m:Hide()
        holder.texture:Show()
    end

    holder.model:Hide()
    holder.texture:Show()

    if style == "class" then
        -- CLASS_ICON_TCOORDS is indexed by class file, which is SECRET when
        -- the unit's identity is restricted. Indexing with a secret key
        -- hard-errors, so the gate is mandatory -- and type() would not catch
        -- it. Falls back to the 2D portrait, which is always safe.
        local classFile = F.GetClassFile(unit)
        if UnitIsPlayer(unit) and F.IsValueNonSecret(classFile) then
            if square then
                -- The "classicon-*" ATLAS is square art. The TCoords route
                -- below cannot produce a square icon at all -- its source
                -- sheet, UI-Classes-Circles, is circular by construction and
                -- no crop rectangle changes that.
                local atlas = "classicon-" .. string.lower(classFile)
                holder.texture:SetTexCoord(0, 1, 0, 1)
                if holder.texture:SetAtlas(atlas, false) ~= false then
                    ApplyMask(holder, false)
                    return
                end
            end
            if CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
                local c = CLASS_ICON_TCOORDS[classFile]
                holder.texture:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
                holder.texture:SetTexCoord(c[1], c[2], c[3], c[4])
                ApplyMask(holder, false)
                return
            end
        end
        -- fall through to 2D
    end

    -- 2D.
    --
    -- AVAILABILITY GATE FIRST. SetPortraitTexture does not fail cleanly for a
    -- unit the client cannot see -- it leaves whatever the portrait system
    -- last resolved, which in practice is the PLAYER. That is why a target or
    -- boss frame can end up wearing your own face. EllesmereUIUnitFrames gates
    -- the identical call on exactly this pair and substitutes a question mark
    -- when it fails, rather than calling and hoping.
    --
    -- UnitIsVisible is the load-bearing half: "exists" is not the same as
    -- "streamed to this client", and it is the second one SetPortraitTexture
    -- actually needs.
    if not (UnitIsConnected(unit) and UnitIsVisible(unit)) then
        holder.texture:SetTexCoord(0.15, 0.85, 0.15, 0.85)
        holder.texture:SetTexture([[Interface\Icons\INV_Misc_QuestionMark]])
        ApplyMask(holder, false)
        return
    end

    -- ORDER MATTERS: SetPortraitTexture RESETS the texture's properties,
    -- texcoords included, so anything set before it is thrown away.
    -- EllesmereUIUnitFrames records the same behaviour ("2D heals what
    -- SetPortraitTexture resets"). Setting the crop first is exactly why the
    -- square option did nothing -- the call wiped it every repaint.
    SetPortraitTexture(holder.texture, unit)

    if square then
        -- The portrait art carries a circular vignette with transparent
        -- corners, which is what makes an uncropped portrait READ as round.
        -- A mask cannot undo that (masks only subtract), so square means
        -- cropping in to the inner region and discarding the vignette.
        holder.texture:SetTexCoord(0.15, 0.85, 0.15, 0.85)
        ApplyMask(holder, false)
    else
        holder.texture:SetTexCoord(0, 1, 0, 1)
        ApplyMask(holder, true)
    end
end
