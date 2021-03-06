`require = require('./cov_require.js')(require)`
paws = require './Paws.coffee' # Circular. Intentionally.

module.exports =
utilities =
   
   _:_ = require 'lodash/dist/lodash.compat.min'

   
   # Third-order function to pass-through the arguments to the first-order body
   passthrough: passthrough =
      (snd) -> (fst) -> ->
         result = fst.apply this, arguments
         snd.call this, result, arguments
   
   # Higher-order function to wrap a function such that it always returns the owner thereof
   chain:    passthrough -> this
   
   # Higher-order function to return the argument given to the function, unless the function
   # modifies it
   modifier: passthrough (result, args) -> result ? args[0]
   
   
   # NYD
   constructify: (opts) ->
      inner = (body) ->
         Wrapper = ->
            
            unless this instanceof Wrapper
               (F = -> @constructor = Wrapper; return this).prototype = Wrapper.prototype; it = new F
               return Wrapper.apply it, arguments
            
            # TODO: Functionality to control arguments passed to the superclass
            Wrapper.__super__?.constructor?.call this
            
            rv = body[ if opts.arguments == 'intact' then 'call' else 'apply' ] this, arguments
            rv = this if typeof rv != 'object' or opts.return
            
            return rv
         
         # Wow. Okay. So, CoffeeScript wraps *our* wrapper in another wrapper, that then calls us
         # (understandably). This means that our `Wrapper` is no longer the *actual type* we're
         # trying to construct (that is, the nominal “constructor function” whose prototype we're
         # trying to construct.)
         #
         # My approach to solving this is to replace *our wrapper*'s prototype with
         # CoffeeScript's-wrapper's prototype, the first time it *looks* like we're getting called
         # from a CoffeeScript wrapper.
         #
         # Unfortunately, my method for testing for “CoffeeScript-wrapper-ness” in the caller, is
         # rather fragile. I don't know how else to reliably go about this, right now.
         # 
         # This *SHOULD NOT* affect you if you're using this in the most common, intended fashion
         # (as a direct tag on a CoffeeScript class.)
         #
         # TODO: This is surely the most fragile thing ever conceived. Contact the Guinness.
         before_interceptor = ->
            cs_wrapper = before_interceptor.caller
            # The method we actually use to test “CoffeeScript-wrapper-ness”: first off, it calls
            # `#apply`, which we've here intercepted. Second, we know that the wrapper itself will
            # have a defined (and non-zero-length) function-name (which *no other function* in
            # CoffeeScript can have); third, we know that the second argument given to `#apply` will
            # be an `arguments` object, and thus have a `callee` property, referring to the
            # CoffeeScript wrapper itself, our caller.
            if cs_wrapper.name?.length > 0 and arguments[1].callee == cs_wrapper
               Wrapper.prototype = cs_wrapper.prototype
               Wrapper.__super__ = cs_wrapper.__super__ if cs_wrapper.__super__?
               Wrapper.apply = Function::apply
            else
               Wrapper.apply = after_interceptor
            return Function::apply.apply Wrapper, arguments
         after_interceptor = ->
            cs_wrapper = after_interceptor.caller
            if cs_wrapper.name?.length > 0 and arguments[1].callee == cs_wrapper
               paws.error """
                  Oh-oh! It looks like a CoffeeScript constructor-wrapper has tried to call a
                         constructor that you've called `constructify()` on, *after* you've
                         otherwise called that function yourself. Due to the (unfortunately,
                         extremely fragile) approach that we take to handle CoffeeScript's
                         unfortunate indirection, you'll have to refactor your code so that
                         CoffeeScript's constructor is *always* called first. \n"""
               throw new ReferenceError "CoffeeScript wrapper called after other constructor invocations"
            return Function::apply.apply Wrapper, arguments
         
         Wrapper.apply = before_interceptor
         return Wrapper
      
      return inner(opts) if typeof opts == 'function'
      return inner
   
   
   # This is a “tag” that's intended to be inserted before CoffeeScript class-definitions:
   # 
   #     parameterizable class Something
   #        constructor: ->
   #           # ...
   #           return this
   # 
   # When tagged thus, the class will provide `Klass.with()(...)` and `instance.with()...` methods.
   # These will store any argument given, temporarily, on `this._`. The intended use thereof is for
   # further parameterizing methods which need complex or variable numbers of arguments in their
   # *actual invocation*, thus leaving no room for the quintessential (and indespensible) “options”
   # argument. An example:
   #
   #     new Arrayish.with(makeAwesome: no)(element, element2, element3 ...)
   # 
   # There are two extremely important caveats to its use:
   #
   #  - First off, CoffeeScript *does not* generate constructors that explicitly return the
   #    constructed value; it's assumed (reasonably enough) that the constructor will always be
   #    called via the `new` invocaton pattern, which ensures such a return. When using a
   #    “parameterized call pattern” as per this function's intended use, the final constructor
   #    itself is *not* called via a `new` invocation pattern (even though such is simulated
   #    reasonably well.)
   #
   #    **tl;dr**: Your constructors *must* explicitly `return this`.
   # 
   #  - Second, because I don't wish to leave extra cruft on the instances of `parameterizable`
   #    ‘classes,’ this implementation automatically deletes the options member at the *end of the
   #    reactor-tick wherein it was defined*. This means both that you must immediately call any
   #    parameterized constructor, and, more importantly, that the options member *will not be
   #    available* within asynchronous calls.
   #    
   #    As an example, the following will not work:
   #
   #        parameterizable class Something
   #           constructor: ->
   #              asynchronousOperation (result) ->
   #                 if (@_.beAwesome) ...
   #    
   #    The idiomatic way around this, is to store the options object to a local variable if you
   #    will be needing it across multiple reactor ticks. This, in my experience, is an edge-case.
   # ----
   # TODO: This could all be a lot more succinct, and prettier.
   parameterizable: (Klass) ->
      Klass.with = (opts) ->
         
         # XXX: Perhaps this should use constructify()?
         # XXX: Should this handle super-constructors?
         F = -> @constructor = Klass; return this
         F:: = Klass::
         it = new F
         
         it.with opts
         bound = _.bind Klass, it
         _.assign bound, Klass
         bound.prototype = Klass.prototype
         bound._ = opts
         process.nextTick => delete bound._
         bound
         
      Klass.prototype.with = (@_) ->
         process.nextTick => delete @_
         return this
      
      return Klass
   
   # Another “tag” for CoffeeScript classes, to cause them to delegate any undefined methods to
   # another class, if they *are* defined on that other class.
   delegated: (member, delegatee) -> (klass) ->
      functions = _(delegatee::).functions().map (f) ->
         mapped = -> delegatee::[f].apply this[member], arguments
         [f, mapped]
      _.defaults klass::, functions.object().valueOf()
      
      return klass
   
   # This is the most robust method I could come up with to detect the presence or absence of
   # `__proto__`-style accessors. It's probably not foolproof.
   hasPrototypeAccessors: do ->
      canHaz = undefined
      return (setTo) ->
         canHaz = setTo if setTo?
         canHaz ? do ->
            (a = new Object).inherits = true
            (b = new Object).__proto__ = a
            return canHaz = !!b.inherits
   
   runInNewContext: do ->
      server = (source, context) ->
         require('vm').createScript(source).runInNewContext(context)
      
      client = (source, context) ->
         semaphore =
            source: source
         
         parent = body(html(window.document))
         $frame = window.document.createElement 'iframe'
         $frame.style.display = 'none'
         parent.insertBefore $frame, parent.firstChild
         $window = $frame.contentWindow
        #$window.document.close()
         
         $parent = body(html($window.document))
         $window.__fromSemaphore = semaphore
         $script = $window.document.createElement 'script'
         $script.text = "window.__fromSemaphore.result = eval(window.__fromSemaphore.source)"
         $parent.insertBefore $script, $parent.firstChild
         
         parent.removeChild $frame
         
         return semaphore.result
      
      nodeFor = (type) -> (node) ->
         node.getElementsByTagName(type)[0] or
         node.insertBefore (node.ownerDocument or node).createElement(type), node.firstChild
      
      html = nodeFor 'html'
      head = nodeFor 'head'
      body = nodeFor 'body'

      return (source, context) ->
         (if process?.browser then client else server).apply this, arguments
   
   # This creates a pseudo-‘subclass’ of a native JavaScript complex-type. Currently only makes
   # sense to run on `Function`.
   # 
   # There's several ways to acheive a trick like this; unfortunately, all of them are severely
   # limited in some crucial way. Herein, I chose two of the most flexible ways, and dynamically
   # choose which to employ based on the capabilities of the hosting JavaScript implementation.
   # ----
   # FIXME: This currently only works for subclassing `Function`, genearlize it out
   # FIXME: The runtime choice between the two implementations is unnecessary
   # TODO: Release this as its own micro-library
   subclass: do ->
      noop = ->
      
      # The first approach, and most flexible of all, is to create `Function` instances with the
      # native `Function` constructor from our own context, and then directly modify the
      # `[[Prototype]]` field thereof with the `__proto__` pseudo-property provided by many
      # implementations.
      # ----
      # FIXME: This should probably try to use standard ES5 methods instead of `__proto__`
      withAccessors = (parent, constructorBody, runtimeBody, intactArguments) ->
         constructor = ->
            that = ->
               body = arguments.callee._runtimeBody ? runtimeBody ? noop
               body[if intactArguments then 'call' else 'apply'] this, arguments
            that.__proto__ = constructor.prototype
            return (constructorBody ? noop).apply(that, arguments) ? that
         
         constructor.prototype = do ->
            C = new Function; C.prototype = parent.prototype; new C
         constructor.prototype.constructor = constructor
         
         constructor
         
      # This approach, while more widely supported (see `runInNewContext`), has a major downside:
      # it results in instances of the returned ‘subclass’ *do not inherit from the local context's
      # `Object` or `Function`.* This means that modifications to `Object.prototype` and similar
      # will not be accessible on instances of the returned subclass.
      # 
      # This is not considered to be too much of a downside, as 1. the vast majority of JavaScript
      # programmers and widely-used JavaScript libraries consider modifying `Object.prototype` to be
      # anathema *already*, and so their code won't be affected by this shortcoming; 2. this
      # downside only applies in environments where `hasPrototypeAccessors` evaluates to `false`
      # (notably, Internet Explorer); and 3. this downside only applies to *our* objects (instances
      # of the returned subclass). I, elliottcable, consider it fairly unlikely for a situation to
      # arise where all of the following are true:
      # 
      #  - A consumer of the Paws API,
      #  - wishes their code to operate in old Internet Explorers,
      #  - while *also* using a library that modifies `Object.prototype`,
      #  - and necessitates utilizing those modifications on objects returned from our APIs.
      # 
      # (All that ... along with the fact that I know of absolutely *no way* to circumvent this.)
      fromOtherContext = (parent, constructorBody, runtimeBody, intactArguments) ->
         parent = utilities.runInNewContext parent.name
         parent._subclassSemaphore =
            runtimeBody: runtimeBody
            intactArguments: intactArguments
         
         constructor = ->
            that = new parent("
               return (arguments.callee._runtimeBody
                    || "+parent.name+"._subclassSemaphore.runtimeBody
                    || function(){})
                  ["+parent.name+"._subclassSemaphore.intactArguments ? 'call':'apply']
                     (this, arguments)")
            (constructorBody ? noop).apply(that, arguments) ? that
         
         constructor.prototype = parent.prototype
         constructor.prototype.constructor = constructor
         
         constructor
      
      return (parent, constructorBody, runtimeBody, intactArguments) ->
         (if utilities.hasPrototypeAccessors() then withAccessors else fromOtherContext)
            .apply this, arguments
   
   
   infect: (globals, wif = utilities) -> _.assign globals, wif
