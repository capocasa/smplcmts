(async function () {
  document.write('<section id="comments-section"><div></div><p></p><form></form></section>')
  var container = document.getElementById('comments-section')
  var comments = container.getElementsByTagName('div')[0]
  var form = container.getElementsByTagName('form')[0]
  var message = container.getElementsByTagName('p')[0]
  var script = new URL(document.currentScript.src)
  var base = script.protocol + script.host
  var url = location.protocol + location.host + location.pathname
  class HTTPException extends Error {}
  var email = null
  async function load(method, path, body) {
    message.innerHTML=''
    var params = {}
    params.headers = {}
    var token = localStorage.getItem('token')
    if (token) params.headers.Authorization = 'Bearer ' + token
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
  function nextAction() {
    if (localStorage.hasOwnProperty('token')) return '/publish'
    return '/signin'
  }
  comments.outerHTML = await load('get', '/comments?url='+url)
  comments = container.getElementsByTagName('div')[0]
  form.outerHTML = await load('get', nextAction())
  form = container.getElementsByTagName('form')[0]
  container.addEventListener("submit", async function (e) {
    e.preventDefault()
    e.stopPropagation()
    let action = e.target.attributes.action.value
    try {
      var formdata = new FormData(e.target)
      if (action == '/confirm') formdata.set('email', email)
      if (action == '/publish') formdata.set('url', url)
      let response = await load(e.target.method, action, formdata)
      if (action == '/signin') email = response
      if (action == '/confirm') {
        localStorage.setItem('token', response)
        email = null
      }
      if (action == '/publish') {
        comments.outerHTML = await load('get', '/comments?url='+url)
        comments = container.getElementsByTagName('div')[0]
      }
      form.outerHTML = await load('get', action == '/signin' ? '/confirm' : nextAction())
      form = container.getElementsByTagName('form')[0]
    } catch (e) {
      if ( ! e instanceof HTTPException) throw e
      message.innerHTML=e.message
    }
  })
})()
