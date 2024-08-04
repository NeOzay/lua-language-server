local vm    = require 'vm'
local files = require 'files'
local guide = require 'parser.guide'
local await = require 'await'
local lang  = require 'language'

---@async
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    ---@async
    guide.eachSourceType(state.ast, 'table', function (src)
        await.delay()

        vm.removeNode(src) -- the node is not updated correctly, reason still unknown
        local defs = vm.getDefs(src)
        local sortedDefs = {}
        for _, def in ipairs(defs) do
            if def.type == 'doc.class' then
                if def.bindSource and guide.isInRange(def.bindSource, src.start) then
                    return
                end
                local className = def.class[1]
                if not sortedDefs[className] then
                    sortedDefs[className] = {}
                end
                local samedefs = sortedDefs[className]
                samedefs[#samedefs+1] = def
            end
            if def.type == 'doc.type.array'
            or def.type == 'doc.type.table' then
                return
            end
        end
        
        local myKeys
        local mykeyscount = 0
        local warnings = {}
        local otherwarnings = {}
        local mark = {}
        for className, samedefs in pairs(sortedDefs) do
            local missedKeys = {}
            local count = 0
            for _, def in ipairs(samedefs) do
                if not def.fields or #def.fields == 0 then
                    goto continue
                end
                
                if not myKeys then
                    myKeys = {}
                    for _, field in ipairs(src) do
                        local key = vm.getKeyName(field) or field.tindex
                        if key then
                            myKeys[key] = true
                            mark[key] = true
                            mykeyscount = mykeyscount + 1
                        end
                    end
                end

                for _, field in ipairs(def.fields) do
                    if  not field.optional
                    and not vm.compileNode(field):isNullable() then
                        local key = vm.getKeyName(field)
                        if not key then
                            local fieldnode = vm.compileNode(field.field)[1]
                            if fieldnode and fieldnode.type == 'doc.type.integer' then
                                ---@cast fieldnode parser.object
                                key = vm.getKeyName(fieldnode)
                            end
                        end

                        if not key then
                            goto continue
                        end

                        if myKeys[key] then
                            count = count +  1
                            mark[key] = nil
                        else
                            if type(key) == "number" then
                                missedKeys[#missedKeys+1] = ('`[%s]`'):format(key)
                            else
                                missedKeys[#missedKeys+1] = ('`%s`'):format(key)
                            end
                        end
                    end
                end
                ::continue::
            end

            if #missedKeys == 0 then
                return
            end
            if mykeyscount - count == 0 or mykeyscount == 0 then
                warnings[#warnings+1] = lang.script('DIAG_MISSING_FIELDS', className, table.concat(missedKeys, ', '))
            elseif #warnings == 0 and count > 0 then
                table.insert(missedKeys, count)
                otherwarnings[className] = missedKeys
            end
        end

        if #warnings == 0 then
            if not next(otherwarnings) then
                return
            else
                local unusedKeys = 0
                for _ in pairs(mark) do
                    unusedKeys = unusedKeys + 1
                end
                for className, missedKeys in pairs(otherwarnings) do
                    local count = table.remove(missedKeys)
                    if unusedKeys == 0 or mykeyscount - count - unusedKeys == 0 then
                        warnings[#warnings+1] = lang.script('DIAG_MISSING_FIELDS', className, table.concat(missedKeys, ', '))
                    end
                end
            end
        end

        callback {
            start   = src.start,
            finish  = src.finish,
            message = table.concat(warnings, '\n')
        }
    end)
end

