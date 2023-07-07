# Weak 变量在对象释放时到底发生了什么？

> TLDR：
>
> 1.  访问 weak 变量与读取 weak 变量的内存是两回事。区别见下图。
> ![whiteboard_exported_image.png](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/3148b5fe59f74d21ae59961c6a7f4bd5~tplv-k3u1fbpfcp-watermark.image?)
> 2. \>= iOS 16 苹果提供了指定类在特定线程释放的方法，可以做一个参考。




## 问题提出

真实案例，都脱胎于业务代码，~~ 有历史积淀的业务代码常常令人内牛满面 ~~。之前网上会有非常多的讨论，建议大家不要在 dealloc 里做太多逻辑，也有不少相关的整理，例如：避免在 dealloc 中使用属性访问，避免在 dealloc 中将 self 赋值给 \_\_weak 变量（crash） 等相关问题。但这次还会讲一个 dealloc 中与 weak 变量相关的冷门知识，遇到了还是很痛的。

## 分析问题

环境：Version 14.2 (14C18)，objc4-866.9 ，iOS 16.2。

本文 demo 链接见：

抽象后的问题非常简单，外部正常 `[[SampleObject alloc] init]` 之后，Assert 是否能够命中？

```Objective-C
static __weak id sWeakObject = nil;

@interface SampleObject : NSObject

@end

@implementation SampleObject

- (instancetype)init {
    if (self = [super init]) {
        sWeakObject = self;
        
        [self testEqual];
    }
    return self;
}

- (void)dealloc {
    [self testEqual];
}

- (void)testEqual {
    BOOL testEqual = sWeakObject == self;
    NSAssert(testEqual, @"What happens？");
}

@end
```

顺便再放一个前置输出（~~ 其实是烟雾弹 ~~）

![image](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/97408256f3da490fb25a08f75358688b~tplv-k3u1fbpfcp-zoom-1.image)

```Objective-C
- (void)testEqual {
    BOOL testEqual = sWeakObject == self;
    NSAssert(testEqual, @"WHY NOT EQUAL???");
}

```

如果知道会中 Assert 的话，可能是刷过一些八股。你可以进一步追问：

1.  在 lldb 里直接 po weak 变量 跟实际代码的访问 weak 变量 有什么不同？

2.  访问一个 weak 变量实际经过了哪些步骤？

3.  weak 变量到底在什么时候会被置空？

4.  我们知道 `dealloc` 在 `objc_destructInstance` 之前， 在 `objc_destructInstance` 中，我们知道是先释放 `strong` 变量，再释放 关联对象，最后将所有使用 `__weak` 修饰的指向该对象的变量置为 nil 。但为什么在 `dealloc` 里访问时，`weak` 变量已经是空了？

~~ 通过对这几个问题的理解来判断面试者是单纯的背八股还是有相关理解。这题真是太阴间了。~~

这些答案在本文最后都会做出解析。

### 访问 Weak 变量时发生了什么？

这里由于 `-rewrite-objc` 只是改写语法，对于 ARC 添加的代码以及 ARC Runtime Support 的解释则无能为力，因此这里就不利用 rewrite 的方式辅助分析了，感兴趣的同学可以自行尝试。在仓库中也贴出了对应的结果。

> the interaction between the ARC runtime and the code generated by the ARC compiler. This is not part of the ARC language specification; instead, it is effectively a language-specific ABI supplement, akin to the “ Itanium ” generic ABI for C++.
>
> <https://clang.llvm.org/docs/AutomaticReferenceCounting.html#runtime-support>

> xcrun -sdk iphonesimulator clang -rewrite-objc -fobjc-arc -stdlib=libc++ -mios-version-min=12.1 -fobjc-runtime=ios-12.1 -Wno-deprecated-declarations WeakVariable.m

```Objective-C
static void _I_SampleObject_testEqual(SampleObject * self, SEL _cmd) {
    BOOL testEqual = sWeakObject == self;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-extra-args"
    do {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-extra-args"
    if (!((testEqual))) { NSString *__assert_file__ = ((NSString * _Nullable (*)(id, SEL, const char * _Nonnull))(void *)objc_msgSend)((id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), (const char *)"WeakVariable.m"); __assert_file__ = __assert_file__ ? __assert_file__ : (NSString *)&__NSConstantStringImpl__var_folders_b1_0fd1b6hs7lz0fm_mh346lybm0000gn_T_WeakVariable_cc93a6_mi_0; ((void (*)(id, SEL, SEL _Nonnull, id  _Nonnull __strong, NSString * _Nonnull __strong, NSInteger, NSString * _Nullable __strong, ...))(void *)objc_msgSend)((id)((NSAssertionHandler * _Nonnull (*)(id, SEL))(void *)objc_msgSend)((id)objc_getClass("NSAssertionHandler"), sel_registerName("currentHandler")), sel_registerName("handleFailureInMethod:object:file:lineNumber:description:"), (SEL)_cmd, (id _Nonnull)self, (NSString *)__assert_file__, (NSInteger)33, (((NSString *)&__NSConstantStringImpl__var_folders_b1_0fd1b6hs7lz0fm_mh346lybm0000gn_T_WeakVariable_cc93a6_mi_1)), (0), (0), (0), (0), (0)); }
#pragma clang diagnostic pop
    } while(0)
#pragma clang diagnostic pop
                                            ;
}
```

通过查看对应的汇编，可以对逻辑进行一个简化：

```Objective-C
(lldb) dis
demo`-[SampleObject testEqual]:
    0x1001ad9fc <+0>:   sub    sp, sp, #0x40
    0x1001ada00 <+4>:   stp    x29, x30, [sp, #0x30]
    0x1001ada04 <+8>:   add    x29, sp, #0x30
    0x1001ada08 <+12>:  stur   x0, [x29, #-0x8]
    0x1001ada0c <+16>:  stur   x1, [x29, #-0x10]
    0x1001ada10 <+20>:  adrp   x0, 8
    0x1001ada14 <+24>:  add    x0, x0, #0x5d8            ; sWeakObject
->  0x1001ada18 <+28>:  bl     0x1001ae074               ; symbol stub for: objc_loadWeakRetained
    0x1001ada1c <+32>:  ldur   x8, [x29, #-0x8]          // 此时 x0 就是 objc_loadWeakRetained 的返回值，后续 x0 一直没有变过，直到再调用 objc_release 进行释放
    0x1001ada20 <+36>:  subs   x8, x0, x8
    0x1001ada24 <+40>:  cset   w8, eq
    0x1001ada28 <+44>:  str    w8, [sp, #0x18]
    0x1001ada2c <+48>:  bl     0x1001ae098               ; symbol stub for: objc_release // 注意 objc_release 传入的参数不是 location ，而是 <+32> 获取的返回值
    0x1001ada30 <+52>:  ldr    w8, [sp, #0x18]
    0x1001ada34 <+56>:  and    w8, w8, #0x1
    0x1001ada38 <+60>:  sturb  w8, [x29, #-0x11]
    0x1001ada3c <+64>:  b      0x1001ada40               ; <+68> at ViewController.m:81:5
    0x1001ada40 <+68>:  ldurb  w8, [x29, #-0x11]
    0x1001ada44 <+72>:  tbnz   w8, #0x0, 0x1001ada98     ; <+156> at ViewController.m:81:5
    0x1001ada48 <+76>:  b      0x1001ada4c               ; <+80> at ViewController.m
    0x1001ada4c <+80>:  ldr    x1, [sp, #0x8]
    0x1001ada50 <+84>:  adrp   x8, 8
    0x1001ada54 <+88>:  ldr    x0, [x8, #0x228]
    0x1001ada58 <+92>:  bl     0x1001ae100               ; objc_msgSend$currentHandler
    0x1001ada5c <+96>:  mov    x29, x29
    0x1001ada60 <+100>: bl     0x1001ae0b0               ; symbol stub for: objc_retainAutoreleasedReturnValue
    0x1001ada64 <+104>: ldr    x1, [sp, #0x8]
    0x1001ada68 <+108>: str    x0, [sp, #0x10]
    0x1001ada6c <+112>: ldur   x2, [x29, #-0x10]
    0x1001ada70 <+116>: ldur   x3, [x29, #-0x8]
    0x1001ada74 <+120>: adrp   x4, 3
    0x1001ada78 <+124>: add    x4, x4, #0xc0             ; @"ViewController.m"
    0x1001ada7c <+128>: mov    x5, #0x51
    0x1001ada80 <+132>: adrp   x6, 3
    0x1001ada84 <+136>: add    x6, x6, #0xe0             ; @
    0x1001ada88 <+140>: bl     0x1001ae120               ; objc_msgSend$handleFailureInMethod:object:file:lineNumber:description:
    0x1001ada8c <+144>: ldr    x0, [sp, #0x10]
    0x1001ada90 <+148>: bl     0x1001ae098               ; symbol stub for: objc_release
    0x1001ada94 <+152>: b      0x1001ada98               ; <+156> at ViewController.m:81:5
    0x1001ada98 <+156>: b      0x1001ada9c               ; <+160> at ViewController.m:82:1
    0x1001ada9c <+160>: ldp    x29, x30, [sp, #0x30]
    0x1001adaa0 <+164>: add    sp, sp, #0x40
    0x1001adaa4 <+168>: ret    
(lldb) 
```

汇编可能有些门槛，我们可以简化一下：获取一个 weak 变量，ARC Compiler 替我们隐式地插入了两个函数，变成了如下的样子。

```Objective-C
id returnWeakValue = objc_loadWeakRetained(sWeakObject);

// after last use sWeakObject
objc_release(returnWeakValue);
```

在我们使用 `sWeakObject` 的期间，我们是先 `retain` ，再 `release` 的，这样的设计符合 `weak` 的语义：如果你获得了 `weak` 变量的时候，`weak` 变量不是 `nil`，那这段使用时间内，这个变量都不会被释放。不然 `weak` 就变成用着用着可能突然消失了，这个肯定不是合理的设计。

这里还需要注意的是，`objc_release` 接受的参数并不是 `sWeakObect` ，而是 `returnWeakValue` 。这是有区别的，这里留一个作业，如果传入了 `sWeakObect` 会发生什么？

> 答案是 double free 。

### objc_loadWeakRetained()

主要调用到了 `obj->rootTryRetain()` 方法，如果满足条件，就会直接返回 `nil` 。而在 `dealloc` 中访问上面 demo 中的 `sWeakObject` 就会返回 NO ，进而直接返回 nil 。

关于一个链路上调用的 `CustomRR` 的解析，具体可以看：[附录：CustomRR ](https://bytedance.feishu.cn/docx/H3HMd4M5bo1LqQxDorSciQ9lnng#OPWAdTYZmoyAR4xPXt3cdjJJnpc)。

```Objective-C
/*
  Once upon a time we eagerly cleared *location if we saw the object 
  was deallocating. This confuses code like NSPointerFunctions which 
  tries to pre-flight the raw storage and assumes if the storage is 
  zero then the weak system is done interfering. That is false: the 
  weak system is still going to check and clear the storage later. 
  This can cause objc_weak_error complaints and crashes.
  So we now don't touch the storage until deallocation completes.
*/

id
objc_loadWeakRetained(id *location)
{
    id obj;
    id result;
    Class cls;

    SideTable *table;
    
 retry:
    // fixme std::atomic this load
    obj = *location;
    if (_objc_isTaggedPointerOrNil(obj)) return obj;
    
    table = &SideTables()[obj];
    
    table->lock();
    if (*location != obj) {
        table->unlock();
        goto retry;
    }
    
    result = obj;

    cls = obj->ISA();
    if (! cls->hasCustomRR()) { // 正常 cls 都不会有
        // Fast case. We know +initialize is complete because
        // default-RR can never be set before then.
        ASSERT(cls->isInitialized());
        if (! obj->rootTryRetain()) {
            result = nil;
        }
    }
    else {
        // Slow case. We must check for +initialize and call it outside
        // the lock if necessary in order to avoid deadlocks.
        // Use lookUpImpOrForward so we can avoid the assert in
        // class_getInstanceMethod, since we intentionally make this
        // callout with the lock held.
        if (cls->isInitialized() || _thisThreadIsInitializingClass(cls)) {
            BOOL (*tryRetain)(id, SEL) = (BOOL(*)(id, SEL))
                lookUpImpOrForwardTryCache(obj, @selector(retainWeakReference), cls);
            if ((IMP)tryRetain == _objc_msgForward) {
                result = nil;
            }
            else if (! (*tryRetain)(obj, @selector(retainWeakReference))) {
                result = nil;
            }
        }
        else {
            table->unlock();
            class_initialize(cls, obj);
            goto retry;
        }
    }
        
    table->unlock();
    return result;
}
```

#### rootRetain

实际按当前的链路传入时，`tryRetain` 一定为 `YES`，`variant` 一定为 `RRVariant::Fast` 。

运行着运行着就会走到对 `newisa.isDeallocating()` 的判断，继而在完成解锁等操作后，返回 `nil` 。

那接下来的问题就是 `isDeallocating()` 的实现以及何时被修改值了。

```Objective-C
ALWAYS_INLINE bool 
objc_object::rootTryRetain()
{
    return rootRetain(true, RRVariant::Fast) ? true : false;
}

ALWAYS_INLINE id
objc_object::rootRetain(bool tryRetain, objc_object::RRVariant variant)
{
    if (slowpath(isTaggedPointer())) return (id)this;

    bool sideTableLocked = false;
    bool transcribeToSideTable = false;

    isa_t oldisa;
    isa_t newisa;

    oldisa = LoadExclusive(&isa().bits);
    
    // 省略大量边界处理

    do {
        transcribeToSideTable = false;
        newisa = oldisa;
        if (slowpath(!newisa.nonpointer)) {
            ClearExclusive(&isa().bits);
            if (tryRetain) return sidetable_tryRetain() ? (id)this : nil;
            else return sidetable_retain(sideTableLocked);
        }
        // don't check newisa.fast_rr; we already called any RR overrides
        if (slowpath(newisa.isDeallocating())) {
            ClearExclusive(&isa().bits);
            if (sideTableLocked) {
                ASSERT(variant == RRVariant::Full);
                sidetable_unlock();
            }
            if (slowpath(tryRetain)) {
                return nil;
            } else {
                return (id)this;
            }
        }
        uintptr_t carry;
        newisa.bits = addc(newisa.bits, RC_ONE, 0, &carry);  // extra_rc++

        if (slowpath(carry)) {
            // newisa.extra_rc++ overflowed
            if (variant != RRVariant::Full) {
                ClearExclusive(&isa().bits);
                return rootRetain_overflow(tryRetain);
            }
            // Leave half of the retain counts inline and 
            // prepare to copy the other half to the side table.
            if (!tryRetain && !sideTableLocked) sidetable_lock();
            sideTableLocked = true;
            transcribeToSideTable = true;
            newisa.extra_rc = RC_HALF;
            newisa.has_sidetable_rc = true;
        }
    } while (slowpath(!StoreExclusive(&isa().bits, &oldisa.bits, newisa.bits)));

    if (variant == RRVariant::Full) {
        if (slowpath(transcribeToSideTable)) {
            // Copy the other half of the retain counts to the side table.
            sidetable_addExtraRC_nolock(RC_HALF);
        }

        if (slowpath(!tryRetain && sideTableLocked)) sidetable_unlock();
    } else {
        ASSERT(!transcribeToSideTable);
        ASSERT(!sideTableLocked);
    }

    return (id)this;
}
```

### Before & In  Dealloc

#### isDeallocating()

可以看到 `isa_t` 是一个 `union` ，其中所有成员都共享同一个内存位置。也就是说其中的 `bits` / `cls` / `ISA_BITFIELD` 都在同一块内存区域，只是读取形式会有所不同。

一些老版本的 runtime 的 ISA_BITFIELD 会有不同的处理，例如 `uintptr_t deallocating : 1;`  会有单独一位记录，而最新版本中已经不再需要了，所以这一位变成了 `unused` （为后续再次修改增加骚操作留下了空间）。

在下面的实现中我们也可以看到 `deallocating` 是可以通过另外两位计数位计算出来的（计算属性）。

```Objective-C
#     define ISA_BITFIELD                                                      \
        uintptr_t nonpointer        : 1;                                       \
        uintptr_t has_assoc         : 1;                                       \
        uintptr_t has_cxx_dtor      : 1;                                       \
        uintptr_t shiftcls          : 33; /*MACH_VM_MAX_ADDRESS 0x1000000000*/ \
        uintptr_t magic             : 6;                                       \
        uintptr_t weakly_referenced : 1;                                       \
        uintptr_t unused            : 1;                                       \
        uintptr_t has_sidetable_rc  : 1;                                       \
        uintptr_t extra_rc          : 19


union isa_t {
    isa_t() { }
    isa_t(uintptr_t value) : bits(value) { }

    uintptr_t bits;

private:
    // Accessing the class requires custom ptrauth operations, so
    // force clients to go through setClass/getClass by making this
    // private.
    Class cls;

public:
#if defined(ISA_BITFIELD)
    struct {
        ISA_BITFIELD;  // defined in isa.h ，其实是复杂的展开，每一个 bit 的定义在最上面
    };

    bool isDeallocating() {
        // 判断特定的位数是否为 0 
        return extra_rc == 0 && has_sidetable_rc == 0;
    }
    void setDeallocating() {
        extra_rc = 0;
        has_sidetable_rc = 0;
    }
#endif
    void setClass(Class cls, objc_object *obj);
    Class getClass(bool authenticated);
    Class getDecodedClass(bool authenticated);
};
```

因此接下来就是看是哪里触发了 `setDeallocating()` 函数，以及触发 `setDeallocating()` 函数在 `dealloc` 里整体的位置在哪里，当然也有可能 `setDeallocating()` 函数没有被调用，外部直接修改 `extra_rc` 与 `has_sidetable_rc` 。

这里先说结论：其实就是没有外部手动调用的，毕竟本来 `extra_rc` 跟 `has_sidetable_rc` 就不会同时存在，并且引用技术是一个个减或者加的，也因此是不需要外部手动调用 `setDeallocating()` 函数。

##### extra_rc && has_sietable_rc

这两个属性背过八股文的同学都知道，就是用来储存引用计数的，如果引用计数持续增加，直到 `extra_rc` 不够存了，就会存到 `sidetable` 里，这时候 `sidetable_rc` 就会成为 1 了。

SideTables 内包含一个 `RefcountMap`，用来保存引用计数，根据对象地址取出其引用计数，类型是 `size_t`。

> 更重要的是，如果 自动引用计数 为 1，extra_rc 实际上为 0，因为它保存的是额外的引用计数，我们通过这个行为能够减少很多不必要的函数调用。
>
> [黑箱中的 retain 和 release](https://draveness.me/rr/)

理解了 `extra_rc` 与 `has_sidetable_rc` 的意思后，我们就更能理解为什么可以通过这两个属性计算出 是否 `deallocating` 了，因为只要额外的引用计数一旦为 0 了（即 没有别的强引用了），并且又在 `release` 的逻辑中，那就会触发实际的释放，这个是符合常识的。

#### 开始 Dealloc 之前发生了什么？

我们知道 dealloc 是从子类调用到父类，因此是从我们自己实现的 dealloc 开始调用起。从我们的表现来看，在进行 -(void)dealloc 之前，就已经完成了设置。因此需要先分析 dealloc 是如何**被**触发的，在触发的链路上我们来看对 `extra_rc` 与 `has_sidetable_rc` 的处理。

先上调用堆栈。会有两种情况，但大同小异，主要就是有没有涉及 sidetable 而已。

```C++
- objc_object::rootRelease
    - objc_object::sidetable_release
        - objc_object::performDealloc
        
- objc_object::rootRelease
    - objc_object::performDealloc
```

##### objc_object::performDealloc()

大部分类不会自己实现 _objc_initiateDealloc 方法，如果一定需要自定义的话，需要调用 _class_setCustomDeallocInitiation 方法。这个跟本文分析无关，想详细了解可以看：[附录：_class_setCustomDeallocInitiation](https://bytedance.feishu.cn/docx/H3HMd4M5bo1LqQxDorSciQ9lnng#Q3K6dStoUolUeZxaiyXc3Kstn5b)。

因此会在 `performDealloc()` 中直接通过消息转发调用 `dealloc` 方法，走到正常的路径中。

```Objective-C
void
objc_object::performDealloc()
{
    if (ISA()->hasCustomDeallocInitiation())
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(_objc_initiateDealloc));
    else
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(dealloc));
}
```

##### objc_object::sidetable_release

`sidetable_release` 是被 `objc_object::rootRelease` 调用的。

```Objective-C
// rdar://20206767
// return uintptr_t instead of bool so that the various raw-isa 
// -release paths all return zero in eax
uintptr_t
objc_object::sidetable_release(bool locked, bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa().nonpointer);
#endif
    SideTable& table = SideTables()[this];

    bool do_dealloc = false;

    if (!locked) table.lock();
    auto it = table.refcnts.try_emplace(this, SIDE_TABLE_DEALLOCATING);
    auto &refcnt = it.first->second;
    if (it.second) {
        do_dealloc = true;
    } else if (refcnt < SIDE_TABLE_DEALLOCATING) {
        // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
        do_dealloc = true;
        refcnt |= SIDE_TABLE_DEALLOCATING;
    } else if (! (refcnt & SIDE_TABLE_RC_PINNED)) {
        refcnt -= SIDE_TABLE_RC_ONE;
    }
    table.unlock();
    if (do_dealloc  &&  performDealloc) {
        this->performDealloc();
    }
    return do_dealloc;
}
```

##### objc_object::rootRelease

```Objective-C
ALWAYS_INLINE bool
objc_object::rootRelease(bool performDealloc, objc_object::RRVariant variant)
{
    if (slowpath(isTaggedPointer())) return false;

    bool sideTableLocked = false;

    isa_t newisa, oldisa;

    oldisa = LoadExclusive(&isa().bits);

    if (variant == RRVariant::FastOrMsgSend) {
        // These checks are only meaningful for objc_release()
        // They are here so that we avoid a re-load of the isa.
        if (slowpath(oldisa.getDecodedClass(false)->hasCustomRR())) {
            ClearExclusive(&isa().bits);
            if (oldisa.getDecodedClass(false)->canCallSwiftRR()) {
                swiftRelease.load(memory_order_relaxed)((id)this);
                return true;
            }
            ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(release));
            return true;
        }
    }

    if (slowpath(!oldisa.nonpointer)) {
        // a Class is a Class forever, so we can perform this check once
        // outside of the CAS loop
        if (oldisa.getDecodedClass(false)->isMetaClass()) {
            ClearExclusive(&isa().bits);
            return false;
        }
    }

retry:
    do {
        newisa = oldisa;
        if (slowpath(!newisa.nonpointer)) {
            ClearExclusive(&isa().bits);
            return sidetable_release(sideTableLocked, performDealloc);
        }
        if (slowpath(newisa.isDeallocating())) {
            ClearExclusive(&isa().bits);
            if (sideTableLocked) {
                ASSERT(variant == RRVariant::Full);
                sidetable_unlock();
            }
            return false;
        }

        // don't check newisa.fast_rr; we already called any RR overrides
        uintptr_t carry;
        newisa.bits = subc(newisa.bits, RC_ONE, 0, &carry);  // extra_rc--
        if (slowpath(carry)) {
            // don't ClearExclusive()
            goto underflow;
        }
    } while (slowpath(!StoreReleaseExclusive(&isa().bits, &oldisa.bits, newisa.bits)));

    if (slowpath(newisa.isDeallocating()))
        goto deallocate;

    if (variant == RRVariant::Full) {
        if (slowpath(sideTableLocked)) sidetable_unlock();
    } else {
        ASSERT(!sideTableLocked);
    }
    return false;

 underflow:
    // newisa.extra_rc-- underflowed: borrow from side table or deallocate

    // abandon newisa to undo the decrement
    newisa = oldisa;

    if (slowpath(newisa.has_sidetable_rc)) {
        if (variant != RRVariant::Full) {
            ClearExclusive(&isa().bits);
            return rootRelease_underflow(performDealloc);
        }

        // Transfer retain count from side table to inline storage.

        if (!sideTableLocked) {
            ClearExclusive(&isa().bits);
            sidetable_lock();
            sideTableLocked = true;
            // Need to start over to avoid a race against 
            // the nonpointer -> raw pointer transition.
            oldisa = LoadExclusive(&isa().bits);
            goto retry;
        }

        // Try to remove some retain counts from the side table.        
        auto borrow = sidetable_subExtraRC_nolock(RC_HALF);

        bool emptySideTable = borrow.remaining == 0; // we'll clear the side table if no refcounts remain there

        if (borrow.borrowed > 0) {
            // Side table retain count decreased.
            // Try to add them to the inline count.
            bool didTransitionToDeallocating = false;
            newisa.extra_rc = borrow.borrowed - 1;  // redo the original decrement too
            newisa.has_sidetable_rc = !emptySideTable;

            bool stored = StoreReleaseExclusive(&isa().bits, &oldisa.bits, newisa.bits);

            if (!stored && oldisa.nonpointer) {
                // Inline update failed. 
                // Try it again right now. This prevents livelock on LL/SC 
                // architectures where the side table access itself may have 
                // dropped the reservation.
                uintptr_t overflow;
                newisa.bits =
                    addc(oldisa.bits, RC_ONE * (borrow.borrowed-1), 0, &overflow);
                newisa.has_sidetable_rc = !emptySideTable;
                if (!overflow) {
                    stored = StoreReleaseExclusive(&isa().bits, &oldisa.bits, newisa.bits);
                    if (stored) {
                        didTransitionToDeallocating = newisa.isDeallocating();
                    }
                }
            }

            if (!stored) {
                // Inline update failed.
                // Put the retains back in the side table.
                ClearExclusive(&isa().bits);
                sidetable_addExtraRC_nolock(borrow.borrowed);
                oldisa = LoadExclusive(&isa().bits);
                goto retry;
            }

            // Decrement successful after borrowing from side table.
            if (emptySideTable)
                sidetable_clearExtraRC_nolock();

            if (!didTransitionToDeallocating) {
                if (slowpath(sideTableLocked)) sidetable_unlock();
                return false;
            }
        }
        else {
            // Side table is empty after all. Fall-through to the dealloc path.
        }
    }

deallocate:
    // Really deallocate.

    ASSERT(newisa.isDeallocating());
    ASSERT(isa().isDeallocating());

    if (slowpath(sideTableLocked)) sidetable_unlock();

    __c11_atomic_thread_fence(__ATOMIC_ACQUIRE);

    if (performDealloc) {
        this->performDealloc();
    }
    return true;
}
```

可以看到在 rootRelease 中当额外的引用技术归零的时候，就会 `goto deallocate;` ，并触发实际的释放流程。

#### Dealloc 内部的调用链路

最后我们补齐下 dealloc 的内部顺序，算是完成最后一块拼图。

```Objective-C

// Replaced by NSZombies
// in NSObject implementation
- (void)dealloc {
    _objc_rootDealloc(self);
}

inline void
objc_object::rootDealloc()
{
    if (isTaggedPointer()) return;  // fixme necessary?

    if (fastpath(isa().nonpointer                     &&
                 !isa().weakly_referenced             &&
                 !isa().has_assoc                     &&
#if ISA_HAS_CXX_DTOR_BIT
                 !isa().has_cxx_dtor                  &&
#else
                 !isa().getClass(false)->hasCxxDtor() &&
#endif
                 !isa().has_sidetable_rc))
    {
        assert(!sidetable_present());
        free(this);
    } 
    else {
        // 我们因为这个对象肯定是有 weakly_referenced 的，因此走这个分支
        object_dispose((id)this);
    }
}


id
object_dispose(id obj)
{
    if (!obj) return nil;

    objc_destructInstance(obj);
    free(obj);

    return nil;
}

/***********************************************************************
* objc_destructInstance
* Destroys an instance without freeing memory.
* Calls C++ destructors.
* Calls ARC ivar cleanup.
* Removes associative references.
* Returns `obj`. Does nothing if `obj` is nil.
**********************************************************************/
void *objc_destructInstance(id obj)
{
    if (obj) {
        // Read all of the flags at once for performance.
        bool cxx = obj->hasCxxDtor();
        bool assoc = obj->hasAssociatedObjects();

        // This order is important.
        if (cxx) object_cxxDestruct(obj); // 在这里调用触发 .cxx_destruct 方法，释放 strong 的变量们
        if (assoc) _object_remove_associations(obj, /*deallocating*/true);
        obj->clearDeallocating(); // 清空引用计数并清除弱引用表，将所有使用 __weak 修饰的指向该对象的变量置为 nil
    }

    return obj;
}
```

实际最后去将 `__weak` 修饰的指向该对象的变量置为 nil 在最后一步。执行完才会实际将内存里清空。

## 结论

1.  在 lldb 里直接 po weak 变量 跟实际代码的访问有什么不同？

> lldb 的访问是直接读取内存，而代码的访问套了 objc\_loadWeakRetained() 方法。所见不即所得。

2.  访问一个 weak 变量实际经过了哪些步骤？

> 先调用 `objc_loadWeakRetained()` 访问计数 + 1，保证在访问过程中不会被释放。在使用完毕后再将 引用计数 -1 。

3.  weak 变量到底在什么时候会被置空？

> 内存中的实际情况话，是在 `objc_destructInstance` 中的最后一步，不在业务代码中能触及到的范围中。自己实现的子类的 `dealloc` 方法远早于这个时机。

4.  我们知道 `dealloc` 在 `objc_destructInstance` 之前， 在 `objc_destructInstance` 中，我们知道是先释放 `strong` 变量，再释放 关联对象，最后将所有使用 `__weak` 修饰的指向该对象的变量置为 nil 。但为什么在 `dealloc` 里访问时，`weak` 变量已经是空了？

> `objc_loadWeakRetained()` 替我们做出了保护。

## 附录：_class_setCustomDeallocInitiation

如果你调用了这个方法，可以实现类似：我这个类一定要在主线程里被释放 类似的问题。我们的播放器之前会遇到类似在 dealloc 里 dispatch 的危险操作（一定要在主线程中停止播放器），可以考虑用这个方案。

```objc
static inline void XXXRunOnMainThread(void (^block)(void)) {
    if (!block) return;
    
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

// maybe called in global queue
- (void)dealloc {
    id someStrongProperty = _aStrongProperty;
    
    XXXRunOnMainThread(^{
        [someStrongProperty doSomethingMustInMainThread];
    });
}

```

本地验证可行，iOS 16 对应的新版本 runtime 里新加的，并且苹果也是用这个方法保证 ViewController 一定在主线程中释放的。


> ![image.png](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/f44c75119aae407ea3c76111886c4727~tplv-k3u1fbpfcp-watermark.image?)
> https://github.com/SwiftOldDriver/iOS-Weekly/blob/3dc47c7cedd6e4afd2ff3ae598cd42cd542c732d/Reports/2022/%23212-2022.08.08.md?plain=1#L74


````Objective-C
/**
 * Mark a class as having custom dealloc initiation.
 *
 * NOTE: if you adopt this function for something other than deallocating on the
 * main thread, please let the runtime team know about it so we can be sure it
 * will work properly for your use case.
 *
 * When this is set, the default NSObject implementation of `-release` will send
 * the `_objc_initiateDealloc` message to instances of this class instead of
 * `dealloc` when the refcount drops to zero. This gives the class the
 * opportunity to customize how `dealloc` is invoked, for example by invoking it
 * on the main thread instead of synchronously in the release call.
 *
 * A default implementation of `_objc_initiateDealloc` is not provided. Classes
 * must implement their own.
 *
 * The implementation of `_objc_initiateDealloc` is expected to eventually call
 * `[self dealloc]`. Note that once `_objc_initiateDealloc` is sent, the object
 * is in a deallocating state. This means:
 *
 * 1. Retaining the object will NOT extend its lifetime.
 * 2. Releasing the object will NOT cause another call to `dealloc` or
 *    `_objc_initiateDealloc`.
 * 3. Existing weak references to the object will produce `nil` when read.
 * 4. Forming new weak references to the object is an error.
 *
 * Because the implementation of `_objc_initiateDealloc` will call
 * `[self dealloc]`, it necessarily runs before any subclass overrides of
 * `dealloc`. Overrides of `dealloc` often rely on the superclass state still
 * being intact and usable, so ensure that `_objc_initiateDealloc` does not free
 * resources that a subclass might still try to access. Most or all of your
 * object teardown work should continue to be in `dealloc` to preserve the
 * expected sequence of events.
 *
 * This call primarily exists to support classes which need to deallocate on the
 * main thread. This can be accomplished by setting the class to use custom
 * dealloc initiation, and then implementing `_objc_initiateDealloc` to call
 * dealloc on the main thread. For example:
 *
 * ```
 * _class_setCustomDeallocInitiation([MyClass class]);
 *
 * - (void)_objc_initiateDealloc {
 *     if (pthread_main_np())
 *         [self dealloc];
 *     else
 *         dispatch_async_f(dispatch_get_main_queue(), self,
 *             _objc_deallocOnMainThreadHelper);
 * }
 * ```
 *
 * (We use `dispatch_async_f` to avoid an unsafe capture of `self` in a block,
 * which could result in the object being released by Dispatch after being
 * freed.)
 *
 * @param cls The class to modify.
 */
OBJC_EXPORT void
_class_setCustomDeallocInitiation(_Nonnull Class cls);
````

这个也就是系统在 iOS 16 上保证 VC 一定在主线程释放的方案。

```Objective-C
//
//  ViewController.m
//  demo
//
//  Created by ByteDance on 2022/11/29.
//

#import "ViewController.h"

#import <objc/message.h>
#import <pthread/pthread.h>

extern void _class_setCustomDeallocInitiation(_Nonnull Class cls);

extern void _objc_deallocOnMainThreadHelper(void * _Nullable context);

static __weak id sWeakObject = nil;

@interface SampleObject : NSObject

@end

@implementation SampleObject

- (instancetype)init {
    if (self = [super init]) {
        sWeakObject = self;
        
        [self testEqual];
    }
    return self;
}

- (void)dealloc {
    [self testEqual];
}

- (void)testEqual {
    BOOL testEqual = sWeakObject == self;
}

- (void)_objc_initiateDealloc {
    if (pthread_main_np()) {
        [self performSelector:NSSelectorFromString(@"dealloc")]; // make ARC(clang) happy
    }
    else {
        dispatch_async_f(dispatch_get_main_queue(), (__bridge void * _Nullable)(self), _objc_deallocOnMainThreadHelper);
    }
}

@end


@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _class_setCustomDeallocInitiation(SampleObject.class);
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        __autoreleasing SampleObject *object = [[SampleObject alloc] init];
    });
}
@end

```

![image](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/39161c8218b64ce492e4b172033d5e26~tplv-k3u1fbpfcp-zoom-1.image)

## 附录：CustomRR

大部分 Class 都不会覆写，ARC 下是不允许覆写的，但是 MRC 下是可以的。

RR 的语义猜测是指 Retain/Release （网上没有找到明确的说明），代指最常见的两个方法（实际不止这两个）。

```Objective-C
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR     (1UL<<2)

struct objc_class : objc_object {
    // Class ISA;
    Class superclass;
    cache_t cache;             // formerly cache pointer and vtable
    class_data_bits_t bits;    // class_rw_t * plus custom rr/alloc flags
    // 省略大量函数
    // ...
    
    bool hasCustomRR() const {
        return !bits.getBit(FAST_HAS_DEFAULT_RR);
    }
    void setHasDefaultRR() {
        bits.setBits(FAST_HAS_DEFAULT_RR);
    }
    void setHasCustomRR() {
        bits.clearBits(FAST_HAS_DEFAULT_RR);
    }
}
```

这个计数位是通过 `RRScanner` 来统计的，就是在 Class & MetaClass 对象初始化的时候动态得去判断 Class List 里是否存在。这个阶段也是在所谓的 runtime lock 阶段的。

```Objective-C
/***********************************************************************
* Locking: write-locks runtimeLock
**********************************************************************/
void
objc_class::setInitialized()

{
    Class metacls;
    Class cls;

    ASSERT(!isMetaClass());

    cls = (Class)this;
    metacls = cls->ISA();

    mutex_locker_t lock(runtimeLock); // 对 runtimeLock 加锁，离开 Scope 后释放

    // Special cases:
    // - NSObject AWZ  class methods are default.
    // - NSObject RR   class and instance methods are default.
    // - NSObject Core class and instance methods are default.
    // adjustCustomFlagsForMethodChange() also knows these special cases.
    // attachMethodLists() also knows these special cases.

    objc::AWZScanner::scanInitializedClass(cls, metacls);
    objc::RRScanner::scanInitializedClass(cls, metacls);
    objc::CoreScanner::scanInitializedClass(cls, metacls);
    // 省略下面的代码了
    // ... 
}
```

RRScanner 继承自 scanner::Mixin ，还有众多 Scanner 都继承自这个类，例如 AWZScanner 与 CoreScanner ，起到了不同的 Runtime 扫描作用。这些都有对应的 技术位 用来储存信息，太具体得大家可以自行翻看。

> AWZScanner 关注 *+alloc / +allocWithZone:*
>
> CoreScanner 关注 *+new, ±class, ±self, ±isKindOfClass:, ±respondsToSelector*

```Objective-C
// Retain/Release methods that are extremely rarely overridden
//
// retain/release/autorelease/retainCount/
// _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
struct RRScanner : scanner::Mixin<RRScanner, RR, PrintCustomRR
#if !SUPPORT_NONPOINTER_ISA
, scanner::Scope::Instances
#endif
> {
    static bool isCustom(Class cls) {
        return cls->hasCustomRR();
    }
    static void setCustom(Class cls) {
        cls->setHasCustomRR();
    }
    static void setDefault(Class cls) {
        cls->setHasDefaultRR();
    }
    static bool isInterestingSelector(SEL sel) {
        return sel == @selector(retain) ||
               sel == @selector(release) ||
               sel == @selector(autorelease) ||
               sel == @selector(_tryRetain) ||
               sel == @selector(_isDeallocating) ||
               sel == @selector(retainCount) ||
               sel == @selector(allowsWeakReference) ||
               sel == @selector(retainWeakReference);
    }
    template <typename T>
    static bool scanMethodLists(T *mlists, T *end) {
        SEL sels[8] = {
            @selector(retain),
            @selector(release),
            @selector(autorelease),
            @selector(_tryRetain),
            @selector(_isDeallocating),
            @selector(retainCount),
            @selector(allowsWeakReference),
            @selector(retainWeakReference),
        };
        return method_lists_contains_any(mlists, end, sels, 8);
    }
};
```

这里可以引申出去，你如果在 ARC 环境下，动态得去 overrite/hook retain 等函数覆盖原有实现，能够断点到吗？其实断不到，除非你再把这个 `FAST_HAS_DEFAULT_RR` 对应的技术位改掉，不然会直接调用到 C 函数，只有计数位对了才会通过 `lookUpImpOrForward` 进行转发，并走到自己定义的方法里。

~~ 当然我没试过，这里后续给一个 demo 试一下。~~

## 引用链接：

<https://github.com/zhangferry/iOSWeeklyLearning/blob/3d90c443a0897fcdcd6572e71893a54446af53b2/WeeklyLearning/iOSWeeklyLearning\\\\_44.md?plain=1#L108>

[探秘 Runtime - Runtime 加载过程 - 掘金](https://juejin.cn/post/6844903872998146056)

[iOS weak 底层实现原理(四):ARC 和 MRC 下 weak 变量的访问过程 - 掘金](https://juejin.cn/post/6867465607072514062)

[OC 内存管理--引用计数器 - 掘金](https://juejin.cn/post/6844903783823048717#heading-0)

<https://draveness.me/rr/>

<https://kikido.github.io/2019/06/24/%E6%8E%A2%E7%A9%B6ARC%E4%B8%8Bdealloc%E5%AE%9E%E7%8E%B0/>