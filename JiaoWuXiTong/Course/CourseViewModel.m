//
//  CourseViewModel.m
//  JiaoWuXiTong
//
//  Created by ZQP on 14-9-17.
//  Copyright (c) 2014年 ZQP. All rights reserved.
//

#import "CourseViewModel.h"
#import "UserInfoManager.h"
#import "TFHpple.h"
#import "CalDataModel.h"
#import "ObjectiveCGenerics.h"
#import "AFNetworking.h"
#import <ReactiveCocoa/ReactiveCocoa.h>


@interface CourseViewModel()
@property (strong, nonatomic) NSArray  *allClasses;

@end
@implementation CourseViewModel
{
    NSMutableArray *ContentArray;
}
-(instancetype)init{
    self=[super init];
    if(!self){
        return nil;
    }
    [self getCourse];
    [self prepare];
    return self;
}
-(void)prepare{
    __weak typeof(self) weakSelf=self;
    [self.didBecomeActiveSignal subscribeNext:^(id x) {
        __strong typeof(self) strongSelf=weakSelf;

        [strongSelf getCourse];
    }];
}
-(void)getCourse{
    AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    
    manager.responseSerializer = [AFHTTPResponseSerializer serializer];
    NSString *uName=[UserInfoManager shareManager].name;
    NSString *zhangHao=[UserInfoManager shareManager].xueHao;
    
    
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    parameters[@"xh"] = zhangHao;
    parameters[@"xm"] = uName;
    parameters[@"gnmkdm"] = @"N121603";
    
    NSURL *url = @"http://jwc.xhu.edu.cn/xskbcx.aspx?";

    
    
    if(uName!=nil&&zhangHao!=nil){
//        NSDictionary *parameters2 = @{@"xm":uName,@"gnmkdm":@"N121603",@"xh":zhangHao};
        
        [manager GET:url
          parameters:parameters
             success:^(AFHTTPRequestOperation *operation, id responseObject) {
                 NSStringEncoding enc = CFStringConvertEncodingToNSStringEncoding (kCFStringEncodingGB_18030_2000);
                 
                 NSData *data=responseObject;
                 NSString *transStr=[[NSString alloc]initWithData:data encoding:enc];
                 
                 LLog(@"huoqushuju: %ld",(long)operation.response.statusCode);
                 LLog(@"数据：%@",transStr);
                 NSString *utf8HtmlStr = [transStr stringByReplacingOccurrencesOfString:@"<meta http-equiv=\"Content-Type\" content=\"text/html; charset=gb2312\">" withString:@"<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"];
                 NSData *htmlDataUTF8 = [utf8HtmlStr dataUsingEncoding:NSUTF8StringEncoding];
                 TFHpple *xpathParser = [[TFHpple alloc]initWithHTMLData:htmlDataUTF8];
                 NSArray *elements  = [xpathParser searchWithXPathQuery:@"//table[@id='Table1']/tr/td/child::text()"];
                 
                 // Access the first cell
                 NSUInteger count=[elements count];
                 NSMutableArray *allContents=[NSMutableArray array];
                 for (int i=0; i<count; i++) {
                     
                     TFHppleElement *element = [elements objectAtIndex:i];
                     
                     // Get the text within the cell tag
                     // NSString *content = [element text];
                     NSString *ta=[element tagName];
                     //                  NSDictionary *dic=[element attributes];
                     NSString *nodeContent=[element content];
                     LLog(@"课程为XX%@%@",nodeContent,ta);
                     [allContents addObject:nodeContent];
                 }
                 
                 [self sortData:allContents];
                 ContentArray = [NSMutableArray arrayWithArray:allContents];
                 
                 
             } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                 LLog(@"Error: %@", [error debugDescription]);
             }];//获取登陆后的网页
        
        
    }
    
}

-(void)sortData:(NSMutableArray*)arrayData{
    
    __block NSMutableIndexSet* indexSet=[NSMutableIndexSet indexSet];
    
    [arrayData enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {//synchronously
        LLog(@"%@",obj);
        NSString *string=obj;
        if([string isEqualToString:@" "]||[string hasPrefix:@"星期"]||[string isEqualToString:@"上午"]||[string isEqualToString:@"下午"]||[string isEqualToString:@"早晨"]||[string isEqualToString:@"晚上"]){
            [indexSet addIndex:idx];
        }
        if([string hasPrefix:@"第"]&&[string hasSuffix:@"节"]){
            [indexSet addIndex:idx];
        }
        if([string isEqualToString:@"时间"]){
            [indexSet addIndex:idx];
        }
        
        
    }];
    [arrayData removeObjectsAtIndexes:indexSet];
    long count=arrayData.count;
    if(count%4==0){
        LLog(@"一共有%lu节课程",count/4);
        NSMutableArray *cach=[NSMutableArray array];
        for(int i=0;i<arrayData.count/4;i++){
            CalDataModel *model=[[CalDataModel alloc]initWithmingCheng:arrayData[i*4] jiaoShi:arrayData[i*4+3] shiJian:arrayData[i*4+1] laoShi:arrayData[i*4+2] xingQi:0 kaiShiZhou:0 jieShuZhou:0];
            [cach addObject:model];
        }
        self.allClasses=[[NSArray alloc]initWithArray:cach];
        
        [(RACSubject *)self.updatedContentSignal sendNext:nil];
    }
}

-(NSString *)titleAtIndexPath:(NSIndexPath *)indexPath{
    
    CalDataModel *model = self.allClasses[indexPath.row];
    return model.mingCheng;
}
-(NSInteger)numberOfSections{
    return 1;
}

-(NSInteger)numberOfItemsInSection:(NSInteger)section{
    return _allClasses.count;
}

@end
