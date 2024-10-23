import pkg/smtp

export smtp

template withAsyncSmtp*(body: untyped) =
  block:
    var smtp {.inject.} = newAsyncSmtp()
    await connect(smtp, config.mailHost, Port config.mailPort)
    try:
      body
    finally:
      await close smtp


