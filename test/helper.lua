--- Общие средства проверок цикла.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.context` и `tnt.id` — берутся из `.rocks`
--- обычным `require`: проверяется этот пакет, а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников и часы, которые
--- двигает проверка, — грузится так же и один раз на процесс: второй
--- экземпляр загрузчика не знал бы, что вытеснил первый, и не вернул бы
--- вытесненное на место.
---
--- Проверки цикла берут всё через помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же
--- файла в наборе, где цикл живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    clock = package.loaded['tnt.testing.clock'].new,
}

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.loop', path = 'tnt/loop.lua' },
}

--- Цикл из исходников.
---
--- Заново на каждую проверку: состояния между проверками у модуля нет,
--- но файл проверок один и тот же, что в наборе, где цикл грузится вместе
--- с исходниками зависимостей, а те состояние держат, — и грузит он цикл
--- в `before_each`, а выгружает в `after_each`.
---@return table
function helper.load()
    return testing.load_sources(helper.MODULES, 'tnt.loop')
end

--- Убирает исходники и возвращает то, что они вытеснили.
function helper.unload()
    testing.unload_sources(helper.MODULES)
end

--- Контекст файбера, которым цикл заводит область такта, — установленная
--- копия, та же, что берёт цикл: область, открытая в проверке, иначе
--- не была бы видна такту, а область такта — проверке.
---@return table
function helper.context()
    return require('tnt.context')
end

--- Опознаватели — установленная копия: по ним видно, что у такта ULID,
--- а не что попало.
---@return table
function helper.id()
    return require('tnt.id')
end

--- Часы, которые двигает только проверка.
---@return TntTestingClock
function helper.clock()
    return testing.clock()
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не строку внутри цикла.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

return helper
