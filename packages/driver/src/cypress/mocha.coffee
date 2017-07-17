_ = require("lodash")
Backbone = require("backbone")
$utils = require("./utils")

mocha = require("mocha")

## don't let mocha polute the global namespace
delete window.mocha
delete window.Mocha

Mocha = mocha.Mocha ? mocha
Runner = Mocha.Runner
Runnable = Mocha.Runnable

runnerRun            = Runner::run
runnerFail           = Runner::fail
runnableRun          = Runnable::run
runnableResetTimeout = Runnable::resetTimeout

# listeners: ->
#   @listenTo @Cypress, "abort", =>
#     ## during abort we always want to reset
#     ## the mocha instance grep to all
#     ## so its picked back up by mocha
#     ## naturally when the iframe spec reloads
#     @grep /.*/
#
#   @listenTo @Cypress, "stop", => @stop()
#
#   return @

  grep: (re) ->
    @_mocha.grep(re)

ui = (specWindow, _mocha) ->
  ## Override mocha.ui so that the pre-require event is emitted
  ## with the iframe's `window` reference, rather than the parent's.
  _mocha.ui = (name) ->
    @_ui = Mocha.interfaces[name]

    if not @_ui
      $utils.throwErrByPath("mocha.invalid_interface", { args: { name } })

    @_ui = @_ui(@suite)

    ## this causes the mocha globals in the spec window to be defined
    ## such as describe, it, before, beforeEach, etc
    @suite.emit("pre-require", specWindow, null, @)

    return @

  _mocha.ui("bdd")

set = (specWindow, _mocha) ->
  ## Mocha is usually defined in the spec when used normally
  ## in the browser or node, so we add it as a global
  ## for our users too
  M = specWindow.Mocha = Mocha
  m = specWindow.mocha = _mocha

  ## also attach the Mocha class
  ## to the mocha instance for clarity
  m.Mocha = M

  ## this needs to be part of the configuration of cypress.json
  ## we can't just forcibly use bdd
  ui(specWindow, _mocha)

globals = (specWindow, reporter) ->
  reporter ?= ->

  _mocha = new Mocha({
    reporter: reporter
    enableTimeouts: false
  })

  ## set mocha props on the specWindow
  set(specWindow, _mocha)

  ## return the newly created mocha instance
  return _mocha

getRunner = (_mocha) ->
  Runner::run = ->
    ## reset our runner#run function
    ## so the next time we call it
    ## its normal again!
    restoreRunnerRun()

    ## return the runner instance
    return @

  _mocha.run()

restoreRunnableResetTimeout = ->
  Runnable::resetTimeout = runnableResetTimeout

restoreRunnerRun = ->
  Runner::run = runnerRun

restoreRunnerFail = ->
  Runner::fail = runnerFail

restoreRunnableRun = ->
  Runnable::run = runnableRun

patchRunnerFail = ->
  ## matching the current Runner.prototype.fail except
  ## changing the logic for determing whether this is a valid err
  Runner::fail = (runnable, err) ->
    ## if this isnt a correct error object then just bail
    ## and call the original function
    if Object.prototype.toString.call(err) isnt "[object Error]"
      return runnerFail.call(@, runnable, err)

    ## else replicate the normal mocha functionality
    ++@failures

    runnable.state = "failed"

    @emit("fail", runnable, err)

patchRunnableRun = (Cypress) ->
  Runnable::run = (args...) ->
    runnable = @

    Cypress.action("mocha:runnable:run", runnable, args)

    runnableRun.apply(runnable, args)

patchRunnableResetTimeout = ->
  Runnable::resetTimeout = ->
    runnable = @

    ms = @timeout() or 1e9

    @clearTimeout()

    getErrPath = ->
      ## we've yield an explicit done callback
      if runnable.async
        "mocha.async_timed_out"
      else
        "mocha.timed_out"

    @timer = setTimeout ->
      errMessage = $utils.errMessageByPath(getErrPath(), { ms })
      runnable.callback new Error(errMessage)
      runnable.timedOut = true
    , ms

restore = ->
  restoreRunnerRun()
  restoreRunnerFail()
  restoreRunnableRun()
  restoreRunnableResetTimeout()

override = (Cypress) ->
  patchRunnerFail()
  patchRunnableRun(Cypress)
  patchRunnableResetTimeout()

create = (specWindow, Cypress, reporter) ->
  restore()

  override(Cypress)

  ## generate the mocha + Mocha globals
  ## on the specWindow, and get the new
  ## _mocha instance
  _mocha = globals(specWindow, reporter)

  _runner = getRunner(_mocha)

  return {
    _mocha

    getRunner: ->
      _runner

    getRootSuite: ->
      _mocha.suite

    options: (runner) ->
      runner.options(_mocha.options)
  }

module.exports = {
  restore

  globals

  create
}
