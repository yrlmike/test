from pathlib import Path
import joblib
import numpy as np
import pandas as pd
import streamlit as st
from sklearn.impute import SimpleImputer

# 1. 参数设置：更换数据时只需修改这里
RESULT_FOLDER = '数据分析结果'

THRESHOLD = 0.5

# 2. 页面与模型路径
st.set_page_config(
    page_title='临床风险预测',
    page_icon='🩺',
    layout='centered'
)

st.title('临床风险预测工具')

MODEL_NAME = st.selectbox(
    '选择算法',
    ['LR', 'KNN', 'RF', 'SVM', 'XGB']
)

st.caption(f'{MODEL_NAME}模型')

current_dir = Path(__file__).resolve().parent

PROJECT_DIR = next(
    (p for p in [current_dir, *current_dir.parents]
     if (p / RESULT_FOLDER / '建模结果').is_dir()),
    None
)

if PROJECT_DIR is None:
    st.error(f'找不到{RESULT_FOLDER}/建模结果文件夹，请检查课程目录。')
    st.stop()

MODEL_FILE = (
    PROJECT_DIR
    / RESULT_FOLDER
    / '建模结果'
    / f'{MODEL_NAME}_models.pkl'
)

if not MODEL_FILE.is_file():
    st.error(f'找不到模型文件：{MODEL_FILE}')
    st.stop()

# 3. 加载模型及变量配置
try:
    bundle = joblib.load(MODEL_FILE)

    # 兼容新旧模型包，不强制要求bundle_schema字段
    required = {'models', 'encoder', 'features', 'input_schema'}

    if not isinstance(bundle, dict) or not required.issubset(bundle):
        raise ValueError('模型包缺少预测所需字段，请检查PKL文件')

    models = bundle['models']
    scalers = bundle.get('scalers') or []
    encoder = bundle['encoder']
    features = list(bundle['features'])
    schema = bundle['input_schema']

    if len(models) != 1:
        raise ValueError('仅支持单模型预测流程')

    if len(scalers) not in (0, 1):
        raise ValueError('预处理器数量与模型不匹配')

    THRESHOLD = float(bundle.get('threshold', 0.5))

except Exception as error:
    st.error(f'模型加载失败：{error}')
    st.stop()

# 检查模型是否包含简单插补器
has_imputer = (
    hasattr(encoder, 'get_params')
    and any(
        isinstance(step, SimpleImputer)
        for step in encoder.get_params(deep=True).values()
    )
)

# 4. 自动生成临床指标输入表单
st.subheader('输入临床指标')

values = {}

with st.form('prediction'):

    for feature in features:

        setting = schema.get(feature)

        if setting is None:
            st.error(f'缺少变量配置：{feature}')
            st.stop()

        if setting['type'] == 'number':

            # 新模型允许将某项指标标记为未测量
            if has_imputer:
                missing = st.checkbox(
                    f'{feature} 未测量',
                    key=f'missing_{feature}'
                )
            else:
                missing = False

            if missing:
                values[feature] = np.nan
            else:
                values[feature] = st.number_input(
                    feature,
                    value=float(setting.get('value', 0.0)),
                    step=float(setting.get('step', 0.1)),
                    key=f'value_{feature}'
                )

        elif setting['type'] == 'category':

            values[feature] = st.selectbox(
                feature,
                options=setting['options'],
                key=f'category_{feature}'
            )

        else:
            st.error(f'不支持的变量类型：{feature}')
            st.stop()

    submitted = st.form_submit_button(
        '开始预测',
        use_container_width=True
    )

# 5. 预测并显示结果
if submitted:

    try:
        patient = pd.DataFrame([values], columns=features)

        # 数值变量统一转换为数值类型，未测量值保留为NaN
        for feature in features:
            if schema[feature]['type'] == 'number':
                patient[feature] = pd.to_numeric(
                    patient[feature],
                    errors='raise'
                )

        # 旧模型如果不支持插补，则禁止缺失值输入
        if patient.isna().any().any() and not has_imputer:
            raise ValueError(
                '当前模型不支持缺失值，请填写完整临床指标'
            )

        # 使用训练时保存的编码器进行插补和编码
        X = encoder.transform(patient)

        if scalers:
            X = scalers[0].transform(X)

        # 模型预测
        model = models[0]

        positive_index = list(model.classes_).index(1)

        probability = float(
            model.predict_proba(X)[0, positive_index]
        )

        st.subheader('预测结果')

        st.metric(
            '阳性预测概率',
            f'{probability:.2%}'
        )

        predicted_class = (
            '阳性' if probability >= THRESHOLD else '阴性'
        )

        st.write(
            f'预测类别：**{predicted_class}**'
            f'（阈值：{THRESHOLD:.2f}）'
        )

        missing_count = int(patient.isna().sum().sum())

        if missing_count > 0:
            st.info(
                f'本次有{missing_count}项指标未测量，'
                '已使用训练阶段保存的简单插补规则处理。'
            )

    except Exception as error:
        st.error(f'预测失败：{error}')