REBOL [
	Title:   "Redbin format encoder for Red compiler"
	Author:  "Nenad Rakocevic"
	File: 	 %redbin.r
	Tabs:	 4
	Rights:  "Copyright (C) 2015 Nenad Rakocevic. All rights reserved."
	License: "BSD-3 - https://github.com/dockimbel/Red/blob/master/BSD-3-License.txt"
]

context [
	header:		make binary! 10'000
	buffer:		make binary! 100'000
	sym-table:	make binary! 10'000
	sym-string:	make binary! 10'000
	symbols:	make hash! 	 1'000						;-- [word1 word2 ...]
	contexts:	make hash!	 1'000						;-- [name [symbols] index ...]
	index:		0
	
	stats:		make block! 100
	profile?:	no
	
	profile: func [blk /local pos][
		foreach item blk [
			unless pos: find/skip stats type? :item 2 [
				repend stats [type? :item 0]
				pos: skip tail stats -2
			]
			pos/2: pos/2 + 1

		]
	]
	
	get-index: does [index - 1]
	
	pad: func [buf [any-string!] n [integer!] /local bytes][
		unless zero? bytes: (length? buf) // n [
			insert/dup tail buf null n - bytes
		]
	]
	
	preprocess-directives: func [blk][
		forall blk [
			if blk/1 = #get-definition [			;-- temporary directive
				value: select extracts/definitions blk/2
				change/only/part blk value 2
			]
		]
	]
	
	emit: func [n [integer!]][insert tail buffer to-bin32 n]
	
	emit-type: func [type [word!] /unit n [integer!]][
		emit select extracts/definitions type
	]
	
	emit-ctx-info: func [word [any-word!] ctx [word! none!] /local entry pos][
		unless ctx [emit -1 return -1]				;-- -1 for global context
		entry: find contexts ctx
		
		either pos: find entry/2 to word! word [
			emit entry/3
			(index? pos) - 1
		][
			emit -1
			-1
		]
	]
	
	emit-float: func [value [decimal!]][
		pad buffer 8
		emit-type 'TYPE_FLOAT
		append buffer IEEE-754/to-binary64 value
	]
	
	emit-char: func [value [integer!]][
		emit-type 'TYPE_CHAR
		emit value
	]
	
	emit-integer: func [value [integer!]][
		emit-type 'TYPE_INTEGER
		emit value
	]
	
	emit-typeset: func [v1 [integer!] v2 [integer!] v3 [integer!] /root][
		emit-type 'TYPE_TYPESET
		emit v1
		emit v2
		emit v3
		
		if root [index: index + 1]
		index - 1
	]
	
	emit-string: func [str [any-string!] /root /local type][
		type: select [
			string! TYPE_STRING
			file!	TYPE_FILE
			url!	TYPE_URL
		] type?/word str
		
		emit extracts/definitions/:type or shift/left 1 8 ;-- header
		emit (index? str) - 1							  ;-- head
		emit length? str
		append buffer str
		pad buffer 4
		
		if root [index: index + 1]
		index - 1
	]
	
	emit-issue: func [value [issue!]][
		emit-type 'TYPE_ISSUE
		emit-symbol to word! form value
	]
	
	emit-symbol: func [word /local pos s][
		word: to word! word
		
		unless pos: find symbols word [
			s: tail sym-string
			repend sym-string [word null]
			append sym-table to-bin32 (index? s) - 1
			append symbols word
			pos: back tail symbols
		]
		emit (index? pos) - 1							;-- emit index of symbol
	]
	
	emit-word: func [word ctx [word! none!] ctx-idx [integer! none!] /local idx][
		emit-type select [
			word!		TYPE_WORD
			set-word!	TYPE_SET_WORD
			get-word!	TYPE_GET_WORD
			refinement! TYPE_REFINEMENT
			lit-word!	TYPE_LIT_WORD
		] type?/word :word
		emit-symbol word
		idx: emit-ctx-info word ctx
		emit any [ctx-idx idx]
	]
	
	emit-block: func [blk [any-block!] /with main-ctx [word!] /sub /local type item binding ctx idx][
		if profile? [profile blk]
		
		type: either all [path? blk get-word? blk/1][
			blk/1: to word! blk/1 						;-- workround for missing get-path! in R2
			'get-path
		][
			type?/word blk
		]
		emit-type select [
			block!		TYPE_BLOCK
			paren!		TYPE_PAREN
			path!		TYPE_PATH
			lit-path!	TYPE_LIT_PATH
			set-path!	TYPE_SET_PATH
			get-path	TYPE_GET_PATH
		] type
		
		preprocess-directives blk
		emit (index? blk) - 1							;-- head field
		emit length? blk
		
		forall blk [
			item: blk/1
			either any-block? :item [
				either with [
					emit-block/sub/with item main-ctx 
				][
					emit-block/sub item
				]
			][
				case [
					unicode-char? :item [
						value: item
						item: #"_"						;-- placeholder just to pass the char! type to item
					]
					any-word? :item [
						ctx: main-ctx
						value: :item
						either all [with local-word? to word! :item][
							idx: get-word-index/with to word! :item main-ctx
						][
							if binding: find-binding :item [
								set [ctx idx] binding
							]
						]
					]
					float-special? :item [
						;emit-fp-special item
						value: :item
					]
				]
				
				switch type?/word :item [
					word!
					set-word!
					lit-word!
					refinement!
					get-word! [emit-word :item ctx idx]
					file!
					url!
					string!	  [emit-string item]
					issue!	  [emit-issue item]
					integer!  [emit-integer item]
					decimal!  [emit-float item]
					char!	  [emit-char to integer! next value]
				]
			]
		]
		unless sub [index: index + 1]
		index - 1										;-- return the block index
	]
	
	emit-context: func [
		name [word!] spec [block!] stack? [logic!] self? [logic!] /root
		/local header
	][
		repend contexts [name spec index]
		header: extracts/definitions/TYPE_CONTEXT or shift/left 1 8 ;-- header
		if stack? [header: header or shift/left 1 29]
		if self?  [header: header or shift/left 1 28]
		
		emit header
		emit length? spec
		foreach word spec [emit-symbol word]
		if root [index: index + 1]
		index - 1
	]
	
	init: does [
		clear header
		clear buffer
		clear sym-table
		clear sym-string
		clear symbols
		clear contexts
		index: 0
	]
	
	finish: func [flags [block! none!]][
		pad sym-string 8
		
		repend header [
			"REDBIN"
			#{0104}										;-- version: 1, flags: symbols
			to-bin32 index - 1							;-- number of root records
			to-bin32 length? buffer						;-- size of records in bytes
			to-bin32 length? symbols
			to-bin32 length? sym-string
			sym-table
			sym-string
		]
		insert buffer header
	]
]