(async function () {
  var container = document.getElementById('smplcmts')
  if (container == null) {
    document.write('<section id="smplcmts"></div>')
    container = document.getElementById('smplcmts')
  }
  container.innerHTML = '<div></div><mark></mark><form></form>'
  var comments = container.getElementsByTagName('div')[0]
  var form = container.getElementsByTagName('form')[0]
  var message = container.getElementsByTagName('mark')[0]
  var script = new URL(document.currentScript.src)
  var base = script.protocol + '//' + script.host
  var url = location.protocol + '//' + location.host + location.pathname
  class HTTPException extends Error {}
  async function load(method, path, body) {
    var params = {}
    params.headers = {}
    params.credentials = 'include'
    if (body) {
      params.headers['Content-Type'] = 'application/x-www-form-urlencoded'
      params.body = new URLSearchParams(body)
    }
    params.method = method
    var response = await fetch(base + path, params)
    var text = await response.text()
    if ( ! response.ok ) throw new HTTPException(text)
    return text
  }
  comments.outerHTML = await load('get', '/comments?url='+url)
  comments = container.getElementsByTagName('div')[0]
  form.outerHTML = await load('get', '/publish?url='+url)
  form = container.getElementsByTagName('form')[0]
  function prev(e) {
    e.preventDefault()
    e.stopPropagation()
  }
  container.addEventListener("submit", async function (e) {
    prev(e)
    let action = e.target.attributes.action.value
    let method = e.target.attributes.method.value
    try {
      var formdata = new FormData(e.target)
      formdata.set('url', url)
      var comment
      for (el of e.target.getElementsByTagName('div'))
        if (el.hasAttribute('contenteditable'))
          comment = el.innerHTML
      formdata.set('comment', comment)
      message.innerText = await load(method, action, formdata)
      form.outerHTML = await load('get', '/publish?url='+url)
      form = container.getElementsByTagName('form')[0]
      if (action == '/publish') {
        comments.outerHTML = await load('get', '/comments?url='+url)
        comments = container.getElementsByTagName('div')[0]
      }
    } catch (e) {
      if ( ! e instanceof HTTPException) throw e
      message.innerText=e.message
    }
  })
  async function followLink(target) {
    let href = target.attributes.href.value
    let method = target.attributes.method.value
    message.innerText = await load(method, href)
    form.outerHTML = await load('get', '/publish?url='+url)
    form = container.getElementsByTagName('form')[0]
    comments.outerHTML = await load('get', '/comments?url='+url)
    comments = container.getElementsByTagName('div')[0]
    if (target.classList.contains("reply")) {
      window.location.hash = "comment-form"
    }
  }
  function copyLink(target) {
    navigator.clipboard.writeText(window.location.href.split('#')[0] + target.attributes.href.value)
    target.classList.add("copied")
    if (target.timeout) {
      clearTimeout(target.timeout)
      delete target.timeout
    }
    target.timeout = setTimeout(function () {
      target.classList.remove("copied")
      delete target.timeout
    }, 3000)
  }
  function buttonCommand(target) {
    for (c of target.classList)
      if (c != "selected")
        return c
  }
  function format(target) {
    let cmd = buttonCommand(target)
    document.execCommand(cmd, false, cmd == 'createLink' ? prompt(`Please enter the link URL`) : null)
  }
  container.addEventListener("click", function (e) {
    if (e.target.tagName == 'A')
      if (e.target.hasAttribute("method"))
        prev(e) || followLink(e.target)
      else if (e.target.classList.contains("share"))
        prev(e) || copyLink(e.target)
      else
        return
    else if (e.target.parentNode.tagName == 'A')
      prev(e) || followLink(e.target.parentNode)
    else if (e.target.tagName == 'BUTTON')
      prev(e) || format(e.target)
  })
  function updateFormat() {
    for (let button of form.getElementsByTagName('button'))
      button.classList.toggle('selected', document.queryCommandState(buttonCommand(button)))
  }
  container.addEventListener("input", async function (e) {
    if (!e.target.hasAttribute("contenteditable")) return
    await load('put', '/cache/comment', {
      comment: e.target.innerHTML,
      url: url
    })
    updateFormat()
  })
  container.addEventListener("keyup", updateFormat)
  container.addEventListener("mouseup", updateFormat)
  container.addEventListener("touchend", updateFormat)
  container.addEventListener("keydown", function(e) {
    if (!e.target.hasAttribute("contenteditable")) return
    switch (e.which) {
    case 13:
      e.preventDefault()
      document.execCommand('insertLineBreak')
    }
  })

  if (window.location.hash == "#comment-form")
    document.getElementById('comment-form').scrollIntoView({behavior: 'smooth'})

})()


