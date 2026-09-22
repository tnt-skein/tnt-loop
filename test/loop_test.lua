--- Тесты периодического цикла. Часы подменяются, ожидание настоящее.

local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.loop')

---@type any
local loop

--- Контекст файбера, которым цикл заводит область такта.
---@type any
local context

--- Опознаватели: по ним видно, что у такта ULID, а не что попало.
---@type any
local id

--- Отметка цикла событий, которую двигает только проверка.
---@type TntTestingClock
local clock

--- Сколько раз такт был выполнен.
---@type number
local ticks

--- Ошибки, о которых цикл сообщил.
---@type string[]
local errors

--- Собирает цикл со счётчиком тактов.
---@param opts table|nil
---@return table
local function build(opts)
    opts = opts or {}

    return loop.new({
        name = opts.name or 'test_loop',
        interval = opts.interval,
        tick = opts.tick or function()
            ticks = ticks + 1
        end,
        scheduler_now = opts.scheduler_now or clock.scheduler_now,
        on_error = opts.on_error or function(err)
            table.insert(errors, err)
        end,
        on_stop = opts.on_stop,
    })
end

g.before_each(function()
    loop = helper.load()
    context = helper.context()
    id = helper.id()
    clock = helper.clock()
    ticks = 0
    errors = {}
end)

g.after_each(function()
    helper.unload()
end)

g.test_fresh_loop_is_stopped = function()
    local runner = build()

    t.assert_equals(runner:running(), false)
end

g.test_interval_defaults_to_five_seconds = function()
    local runner = build()

    t.assert_equals(runner.interval, 5)
end

g.test_interval_is_taken_from_the_options = function()
    local runner = build({ interval = 3 })

    t.assert_equals(runner.interval, 3)
end

g.test_interval_changes_on_the_fly = function()
    -- Настройки приходят из конфигурации кластера и меняются вместе с ней,
    -- а цикл к этому времени уже собран.
    local runner = build({ interval = 3 })

    runner:set_interval(7)

    t.assert_equals(runner.interval, 7)
end

g.test_cleared_interval_falls_back_to_the_default = function()
    local runner = build({ interval = 3 })

    runner:set_interval(nil)

    t.assert_equals(runner.interval, 5)
end

g.test_pause_counts_from_the_start_of_the_tick = function()
    -- Иначе период растёт вместе с временем такта, и частота проверок
    -- падает ровно тогда, когда наблюдение нужнее всего.
    local runner = build({ interval = 5 })
    local started = clock.scheduler_now()

    clock.advance(2)

    t.assert_equals(runner:pause_after(started), 3)
end

g.test_long_tick_gets_no_pause = function()
    local runner = build({ interval = 5 })
    local started = clock.scheduler_now()

    clock.advance(30)

    t.assert_equals(runner:pause_after(started), 0)
end

g.test_instant_tick_gets_the_whole_interval = function()
    local runner = build({ interval = 5 })

    t.assert_equals(runner:pause_after(clock.scheduler_now()), 5)
end

g.test_waiting_is_skipped_when_stopped = function()
    local runner = build()

    t.assert_equals(runner:wait_for(60), false)
end

g.test_waiting_is_skipped_for_an_elapsed_pause = function()
    local runner = build()
    runner:start()

    t.assert_equals(runner:wait_for(0), false)

    runner:stop()
end

g.test_waiting_is_skipped_for_a_negative_pause = function()
    local runner = build()
    runner:start()

    t.assert_equals(runner:wait_for(-1), false)

    runner:stop()
end

g.test_waiting_happens_while_running = function()
    local runner = build()
    runner:start()

    t.assert_equals(runner:wait_for(0.01), true)

    runner:stop()
end

g.test_loop_ticks_until_stopped = function()
    local runner = build({ interval = 0.01, scheduler_now = fiber.clock })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(ticks >= 2, true)
    end)

    runner:stop()

    t.assert_equals(runner:running(), false)

    -- Удачный такт обработчику падений не достаётся.
    t.assert_equals(errors, {})
end

g.test_stop_wakes_the_waiting_loop = function()
    -- Иначе выключение задерживается на целый период: узел, который
    -- выводят из наблюдения, продолжал бы его вести.
    local runner = build({ interval = 60, scheduler_now = fiber.clock })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(ticks >= 1, true)
    end)

    local started = fiber.clock()
    runner:stop()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(runner.fiber:status(), 'dead')
    end)

    t.assert_equals(fiber.clock() - started < 5, true)
end

g.test_start_twice_keeps_one_loop = function()
    local runner = build({ interval = 60, scheduler_now = fiber.clock })

    runner:start()
    local first = runner.fiber
    runner:start()

    t.assert_equals(runner.fiber, first)

    runner:stop()
end

g.test_restart_without_a_yield_leaves_one_loop = function()
    -- Перечитывание конфигурации гасит цикл и тут же поднимает его снова,
    -- не уступая между этими вызовами. Прежний фибер, проснувшись, видит
    -- цикл идущим — и без номера запуска продолжал бы такты рядом с новым.
    local runner = build({ interval = 60, scheduler_now = fiber.clock })

    runner:start()
    ---@type any
    local first = runner.fiber
    runner:stop()
    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(first:status(), 'dead')
    end)

    t.assert_equals(runner.fiber:status(), 'suspended')
    t.assert_equals(ticks, 2)

    runner:stop()
end

g.test_stop_without_start_is_harmless = function()
    local runner = build()

    runner:stop()

    t.assert_equals(runner:running(), false)
end

g.test_stop_calls_the_handler = function()
    local stopped = false
    local runner = build({
        on_stop = function()
            stopped = true
        end,
    })

    runner:start()
    runner:stop()

    t.assert_equals(stopped, true)
end

g.test_handler_is_not_called_without_a_start = function()
    -- Освобождение того, что не занималось, вредно: остановленный цикл
    -- ничего не держит.
    local stopped = false
    local runner = build({
        on_stop = function()
            stopped = true
        end,
    })

    runner:stop()

    t.assert_equals(stopped, false)
end

g.test_broken_tick_does_not_kill_the_loop = function()
    -- Мёртвый фибер не сообщает о себе ничем, и молчащий цикл выглядит
    -- точно так же, как цикл, которому не о чем сообщить.
    local runner = build({
        interval = 0.01,
        scheduler_now = fiber.clock,
        tick = function()
            ticks = ticks + 1
            error('такт не удался')
        end,
    })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(ticks >= 2, true)
    end)

    runner:stop()

    t.assert_str_contains(errors[1], 'такт не удался')
end

g.test_broken_tick_without_a_handler_is_survived = function()
    local runner = build({
        interval = 0.01,
        scheduler_now = fiber.clock,
        on_error = nil,
        tick = function()
            ticks = ticks + 1
            error('такт не удался')
        end,
    })

    -- Обработчик не задан вовсе: цикл всё равно обязан выжить.
    runner.on_error = nil
    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(ticks >= 2, true)
    end)

    runner:stop()
end

g.test_fiber_is_named = function()
    -- Безымянный фибер не найти ни в fiber.info, ни в отладке.
    local named
    local runner = build({
        name = 'test_loop',
        interval = 60,
        scheduler_now = fiber.clock,
        tick = function()
            named = fiber.self():name()
        end,
    })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(named, 'test_loop')
    end)

    runner:stop()
end

g.test_default_clock_keeps_the_loop_going = function()
    -- Часы не подменены: с неработающими цикл сделает один такт и умрёт,
    -- не сообщив о себе ничем.
    local runner = loop.new({
        name = 'test_loop',
        interval = 0.01,
        tick = function()
            ticks = ticks + 1
        end,
    })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(ticks >= 3, true)
    end)

    runner:stop()
end

g.test_tick_that_does_not_yield_keeps_the_period = function()
    -- Пауза уходит в ожидание, а оно отсчитывает срок от отметки цикла
    -- событий. Посчитанная по настоящим часам, пауза после такта, который
    -- работает не уступая, кончилась бы раньше на всё время его работы.
    local real = require('clock')
    local starts = {}

    local runner = loop.new({
        name = 'test_loop',
        interval = 0.1,
        tick = function()
            local began = real.monotonic()

            table.insert(starts, began)

            repeat
                ticks = ticks + 1
            until real.monotonic() - began >= 0.05
        end,
    })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_ge(#starts, 3)
    end)

    runner:stop()

    -- Второй и третий, а не первый и второй: первый такт начинается
    -- с отметки, оставшейся от проверки, и её отставание — не дело цикла.
    t.assert_ge(starts[3] - starts[2], 0.1 - 0.005)
end

g.test_long_name_does_not_break_the_start = function()
    -- Имя приходит от вызывающего пакета: слишком длинное Tarantool
    -- отвергает, и цикл не начался бы вовсе.
    local runner = build({
        name = string.rep('failover_coordinator_', 20),
        interval = 60,
        scheduler_now = fiber.clock,
    })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(ticks >= 1, true)
    end)

    runner:stop()
end

g.test_throwing_error_handler_does_not_kill_the_loop = function()
    -- Бросок обработчика убил бы фибер: такты прекратились бы молча,
    -- а `running()` отвечал бы «да» — ровно то, от чего защищён такт.
    local runner = build({
        interval = 0.01,
        scheduler_now = fiber.clock,
        tick = function()
            error('такт не удался')
        end,
        on_error = function(err)
            table.insert(errors, err)
            error('журнал недоступен')
        end,
    })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_ge(#errors, 2)
    end)

    t.assert_equals(runner.fiber:status(), 'suspended')

    runner:stop()

    t.assert_str_contains(errors[2], 'такт не удался')
end

-- ── Настройки ────────────────────────────────────────────────────────

g.test_wrong_settings_blame_the_caller = function()
    -- Ошибка в настройках — ошибка программиста, и в фибере её не видно:
    -- цикл без имени умирал бы первой строкой фибера, отвечая «идёт»,
    -- а такт, который не функция, падал бы каждый период.
    local tick = function() end

    helper.assert_blamed({
        {
            function()
                loop.new(nil)
            end,
            'настройки цикла — таблица, а не nil',
        },
        {
            function()
                loop.new({ tick = tick })
            end,
            'настройки цикла.name — непустая строка, а не nil',
        },
        {
            function()
                loop.new({ name = '', tick = tick })
            end,
            'настройки цикла.name — непустая строка, а не пустая',
        },
        {
            function()
                loop.new({ name = 'poller' })
            end,
            'настройки цикла.tick — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                loop.new({ name = 'poller', tick = 'poll' })
            end,
            'настройки цикла.tick — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                loop.new({ name = 'poller', tick = tick, interval = 0 })
            end,
            'настройки цикла.interval — число больше 0, а не 0',
        },
        {
            function()
                loop.new({ name = 'poller', tick = tick, interval = '5' })
            end,
            'настройки цикла.interval — число больше 0, а не строка',
        },
        {
            function()
                loop.new({ name = 'poller', tick = tick, scheduler_now = 1000 })
            end,
            'настройки цикла.scheduler_now — функция или вызываемая таблица, а не число',
        },
        {
            function()
                loop.new({ name = 'poller', tick = tick, on_error = 'log' })
            end,
            'настройки цикла.on_error — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                loop.new({ name = 'poller', tick = tick, on_stop = true })
            end,
            'настройки цикла.on_stop — функция или вызываемая таблица, а не логическое значение',
        },
    })
end

g.test_misspelt_handler_is_refused = function()
    -- Обработчик с опечаткой в имени иначе просто не применился бы,
    -- и падения тактов уходили бы в пустоту.
    helper.assert_blamed({
        {
            function()
                loop.new({ name = 'poller', tick = function() end, on_eror = print })
            end,
            'настройки цикла: ключа «on_eror» нет, есть interval, name, on_error, on_stop, scheduler_now, tick',
        },
    })
end

g.test_wrong_interval_on_the_fly_blames_the_caller = function()
    -- Арифметика паузы идёт вне защиты такта: строка в периоде убила бы
    -- фибер молча.
    local runner = build({ interval = 3 })

    helper.assert_blamed({
        {
            function()
                runner:set_interval('5')
            end,
            'период такта — число, а не строка',
        },
        {
            function()
                runner:set_interval(0 / 0)
            end,
            'период такта — число, а не NaN',
        },
    })

    t.assert_equals(runner.interval, 3)
end

g.test_non_positive_interval_on_the_fly_means_no_pause = function()
    -- Период ставят и из самого такта, и там ноль значит «следующий
    -- такт — сразу».
    local runner = build({ interval = 3 })

    runner:set_interval(0)

    t.assert_equals(runner:pause_after(clock.scheduler_now()), 0)

    runner:set_interval(-1)

    t.assert_equals(runner:pause_after(clock.scheduler_now()), 0)
end

g.test_callable_table_is_a_tick = function()
    -- Такт — всё, что можно позвать: объект с `__call` тоже.
    local runner = build({
        interval = 60,
        scheduler_now = fiber.clock,
        tick = setmetatable({}, {
            __call = function()
                ticks = ticks + 1
            end,
        }),
    })

    runner:start()
    runner:stop()

    t.assert_equals(ticks, 1)
end

g.test_null_interval_is_the_default = function()
    -- `null` из YAML и JSON приходит `box.NULL`: проверка необязательного
    -- его пропускает, а в фибере он сломал бы арифметику паузы.
    local runner = build({ interval = box.NULL })

    t.assert_equals(runner.interval, 5)

    runner:set_interval(3)
    runner:set_interval(box.NULL)

    t.assert_equals(runner.interval, 5)
end

g.test_null_clock_is_the_scheduler_clock = function()
    -- Часы `box.NULL` — те же, что не заданы: звать cdata фибер не смог бы.
    local runner = build({ interval = 0.01, scheduler_now = box.NULL })

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_ge(ticks, 3)
    end)

    runner:stop()
end

-- ── Внеочередной такт ────────────────────────────────────────────────

--- Ждёт, пока тактов станет не меньше указанного.
---@param count number
local function await_ticks(count)
    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_ge(ticks, count)
    end)
end

g.test_wake_interrupts_the_pause = function()
    -- Событие, о котором цикл узнал толчком, иначе ждало бы конца
    -- периода: время реакции равнялось бы периоду опроса.
    local runner = build({ interval = 60, scheduler_now = fiber.clock })

    runner:start()
    await_ticks(1)

    local started = fiber.clock()
    runner:wake()
    await_ticks(2)

    t.assert_lt(fiber.clock() - started, 5)

    -- Ровно один внеочередной такт: толчок не превращает цикл в бег без пауз.
    fiber.sleep(0.05)
    t.assert_equals(ticks, 2)

    runner:stop()
end

g.test_wake_during_a_tick_is_not_lost = function()
    -- Такт мог снять состояние до события: следующий идёт за ним без паузы.
    local runner = build({
        interval = 60,
        scheduler_now = fiber.clock,
        tick = function()
            ticks = ticks + 1
            fiber.sleep(0.05)
        end,
    })

    runner:start()
    await_ticks(1)

    -- Такт ещё спит: толчок приходит посреди него.
    runner:wake()
    await_ticks(2)

    fiber.sleep(0.1)
    t.assert_equals(ticks, 2)

    runner:stop()
end

g.test_wakes_before_a_tick_collapse_into_one = function()
    -- Толчки не копятся: один такт снимает всё, что случилось.
    local runner = build({ interval = 60, scheduler_now = fiber.clock })

    runner:start()
    await_ticks(1)

    runner:wake()
    runner:wake()
    runner:wake()
    await_ticks(2)

    fiber.sleep(0.05)
    t.assert_equals(ticks, 2)

    runner:stop()
end

g.test_wake_on_a_stopped_loop_is_harmless = function()
    -- Остановленный цикл ничего не ждёт, и будить в нём нечего.
    local runner = build()

    runner:wake()

    t.assert_equals(runner.woken, false)
    t.assert_equals(runner:running(), false)
end

g.test_waiting_is_skipped_after_a_wake = function()
    local runner = build()
    runner:start()

    runner:wake()

    t.assert_equals(runner:wait_for(60), false)

    runner:stop()
end

g.test_wake_is_forgotten_by_the_next_start = function()
    -- Толчок, оставшийся от прошлой жизни цикла, не должен укорачивать
    -- первую паузу новой.
    local runner = build({ interval = 60, scheduler_now = fiber.clock })

    runner:start()
    await_ticks(1)
    runner:stop()

    -- Прежний фибер отпускается до нового запуска: остановка будит его,
    -- а не ждёт, и запущенный раньше его смерти цикл получил бы два фибера.
    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(runner.fiber:status(), 'dead')
    end)

    runner.woken = true

    ticks = 0
    runner:start()
    await_ticks(1)

    fiber.sleep(0.05)
    t.assert_equals(ticks, 1)
    t.assert_equals(runner.woken, false)

    runner:stop()
end

-- ── Область такта ────────────────────────────────────────────────────

--- Останавливает цикл и дожидается смерти его фибера.
---
--- Такт, застигнутый остановкой посреди уступки, доработал бы уже
--- в соседней проверке и дописал бы ей свои записи.
---@param runner table
local function stop_and_bury(runner)
    runner:stop()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_equals(runner.fiber:status(), 'dead')
    end)
end

--- Запускает цикл, дожидается двух тактов и хоронит его.
---
--- Счёт — по записям самой проверки, а не по общему счётчику тактов.
---@param seen table Куда такт кладёт то, что видел; по его длине и ждём
---@param opts table Настройки цикла поверх коротких периода и часов
local function two_ticks(seen, opts)
    opts.interval = 0.01
    opts.scheduler_now = fiber.clock

    local runner = build(opts)

    runner:start()

    t.helpers.retrying({ timeout = 2, delay = 0.01 }, function()
        t.assert_ge(#seen, 2)
    end)

    stop_and_bury(runner)
end

g.test_tick_runs_under_a_request_id_of_its_own = function()
    -- Записи одного такта иначе нечем связать между собой: опознаватель
    -- держится весь такт, и уступка управления посреди него его не меняет.
    local seen = {}

    two_ticks(seen, {
        tick = function()
            local before = context.get(context.REQUEST_ID)

            fiber.sleep(0)
            table.insert(seen, { before = before, after = context.get(context.REQUEST_ID) })
        end,
    })

    t.assert_equals(id.is_ulid(seen[1].before), true)
    t.assert_equals(seen[1].after, seen[1].before)
end

g.test_every_tick_gets_a_new_request_id = function()
    -- Такт — одна операция цикла: записи соседних тактов не сливаются.
    local seen = {}

    two_ticks(seen, {
        tick = function()
            table.insert(seen, context.get(context.REQUEST_ID))
        end,
    })

    t.assert_equals(id.is_ulid(seen[2]), true)
    t.assert_not_equals(seen[2], seen[1])
end

g.test_failed_tick_is_reported_under_its_request_id = function()
    -- У происшествия в такте есть номер, по которому искать в журнале:
    -- запись о падении несёт тот же опознаватель, что и записи такта.
    local ticked = {}
    local reported = {}

    two_ticks(reported, {
        tick = function()
            table.insert(ticked, context.get(context.REQUEST_ID))
            error('такт не удался')
        end,
        on_error = function()
            table.insert(reported, context.get(context.REQUEST_ID))
        end,
    })

    t.assert_equals(id.is_ulid(reported[1]), true)
    t.assert_equals(reported[1], ticked[1])
    t.assert_equals(reported[2], ticked[2])
end

g.test_loop_does_not_inherit_the_context_of_its_starter = function()
    -- Цикл, лениво заведённый запросом, не несёт его опознаватель во всех
    -- тактах до перезапуска узла.
    local seen = {}
    local runner = build({
        interval = 60,
        scheduler_now = fiber.clock,
        tick = function()
            table.insert(seen, context.get(context.REQUEST_ID))
        end,
    })

    context.run({ [context.REQUEST_ID] = 'r-7' }, function()
        runner:start()
    end)

    stop_and_bury(runner)

    t.assert_equals(id.is_ulid(seen[1]), true)
end

g.test_there_is_no_area_between_ticks = function()
    -- Область живёт ровно такт: ни фибер цикла в паузе, ни запустивший
    -- его после запуска опознавателя такта не держат.
    local runner = build({ interval = 60, scheduler_now = fiber.clock })

    runner:start()
    await_ticks(1)

    t.assert_equals(runner.fiber.storage[context.STORAGE_KEY], nil)
    t.assert_equals(context.get(context.REQUEST_ID), nil)

    stop_and_bury(runner)
end
